namespace :plex do
  desc "Refresh the local Plex sharing snapshot"
  task refresh: :environment do
    STDOUT.sync = true
    machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER in .env")
    ENV["PLEX_HISTORY_DAYS"] ||= "730"

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "Refreshing Plex shares for #{machine_identifier}..."
    puts "History scan: page_size=#{ENV.fetch('PLEX_HISTORY_PAGE_SIZE', '1000')} max_pages=#{ENV.fetch('PLEX_HISTORY_MAX_PAGES', 'all')}"
    history_window = ENV["PLEX_HISTORY_DAYS"].presence
    puts "History window: #{history_window && !history_window.casecmp('all').zero? ? "#{history_window}d" : "all"}"
    refresh_run = RefreshRun.create!(
      machine_identifier: machine_identifier,
      status: "running",
      admin_email: ENV["ADMIN_EMAIL"].presence || "rake",
      include_history: true,
      started_at: Time.current,
      last_message: "Command-line refresh started"
    )
    progress_recorder = Plex::RefreshProgressRecorder.new(refresh_run)

    snapshot = Plex::SnapshotRefresh.new(
      client: Plex::Client.from_env,
      machine_identifier: machine_identifier,
      progress: lambda do |event|
        progress_recorder.call(event)
        if event[:phase] == "account"
          puts "Account lookup #{event.fetch(:index)}/#{event.fetch(:total)}: #{event.fetch(:label)}; #{event.fetch(:matches)} users matched, #{event.fetch(:remaining)} remaining"
        else
          message = "History page #{event.fetch(:page)} retrieved: #{event.fetch(:rows)} rows, #{event.fetch(:matches)} users matched, #{event.fetch(:remaining)} remaining"
          message += " (#{event.fetch(:stop_reason)})" if event[:stop_reason].present?
          puts message
        end
        checkpoint_id = ShareSnapshot.where(machine_identifier: machine_identifier).latest_first.pick(:id)
        puts "Checkpoint snapshot ##{checkpoint_id} saved" if checkpoint_id
        if event[:stop_reason].present? && event[:remaining_labels].present?
          puts "Unmatched users: #{event[:remaining_labels].to_sentence}"
        end
      end
    ).call

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    streamed_count = snapshot.users.count { |user| user["last_streamed_at"].present? }
    library_count = snapshot.libraries.size
    user_count = snapshot.users.size

    puts "Saved snapshot ##{snapshot.id}"
    puts "Users: #{user_count}"
    puts "Libraries: #{library_count}"
    puts "Users with last-streamed data: #{streamed_count}"
    puts "Fetched at: #{snapshot.fetched_at}"
    puts "Elapsed: #{elapsed.round(1)}s"
    refresh_run.update!(
      status: "completed",
      share_snapshot_id: snapshot.id,
      finished_at: Time.current,
      last_message: "Saved snapshot ##{snapshot.id}"
    )
  rescue StandardError => error
    refresh_run&.update!(
      status: "failed",
      finished_at: Time.current,
      error_message: error.message,
      last_message: "Command-line refresh failed"
    )
    raise
  end

  desc "Backfill local Plex playback history without refreshing shares"
  task backfill_history: :environment do
    STDOUT.sync = true
    machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER in .env")
    page_size = ENV.fetch("PLEX_HISTORY_PAGE_SIZE", "1000").to_i.clamp(1, 2_000)
    max_pages = history_max_pages
    start_page = ENV.fetch("PLEX_HISTORY_START_PAGE", "1").to_i.clamp(1, 10_000)
    viewed_after = history_viewed_after
    client = Plex::Client.from_env
    page = start_page - 1
    pages_scanned = 0
    total_rows = 0
    total_saved = 0
    stopped_on_error = false
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refresh_run = RefreshRun.create!(
      machine_identifier: machine_identifier,
      status: "running",
      admin_email: "rake:backfill",
      include_history: true,
      started_at: Time.current,
      last_message: "History backfill started at page #{start_page}"
    )

    puts "Backfilling Plex playback history for #{machine_identifier}..."
    puts "History scan: page_size=#{page_size} max_pages=#{max_pages || 'all'}"
    puts "History retries: #{history_retries}"
    puts "Starting page: #{start_page}"
    puts "History window: #{viewed_after ? "#{ENV['PLEX_HISTORY_DAYS']}d" : 'all'}"

    loop do
      break if max_pages && pages_scanned >= max_pages

      history = fetch_history_page_with_retries(client, page: page, page_size: page_size)
      unless history
        stopped_on_error = true
        puts "Stopped before page #{page + 1}. Rerun with PLEX_HISTORY_START_PAGE=#{page + 1} to resume."
        break
      end
      if history.empty?
        puts "History page #{page + 1} retrieved: 0 rows (empty page)"
        break
      end

      in_window_history = viewed_after ? history.reject { |stream| stream[:viewed_at].to_i < viewed_after.to_i } : history
      saved_count = PlexStreamEvent.upsert_streams!(machine_identifier, in_window_history)
      total_rows += history.size
      total_saved += saved_count
      pages_scanned += 1
      refresh_run.update!(
        history_pages_retrieved: page + 1,
        history_rows_retrieved: refresh_run.history_rows_retrieved + history.size,
        last_message: "History page #{page + 1} retrieved"
      )

      stop_reason = if viewed_after && history_older_than_window?(history, viewed_after)
        "reached history window"
      elsif history.size < page_size
        "last page"
      end
      message = "History page #{page + 1} retrieved: #{history.size.to_fs(:delimited)} rows, " \
        "#{in_window_history.size.to_fs(:delimited)} in window, #{saved_count.to_fs(:delimited)} new events"
      message += " (#{stop_reason})" if stop_reason
      puts message
      Rails.logger.info(
        "[plex.backfill_history] page=#{page + 1} rows=#{history.size} " \
        "in_window=#{in_window_history.size} new_events=#{saved_count} stop_reason=#{stop_reason || 'none'}"
      )
      break if stop_reason

      page += 1
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    puts stopped_on_error ? "Backfill stopped" : "Backfill complete"
    puts "Pages scanned: #{pages_scanned.to_fs(:delimited)}"
    puts "Rows scanned: #{total_rows.to_fs(:delimited)}"
    puts "New events saved: #{total_saved.to_fs(:delimited)}"
    puts "Elapsed: #{elapsed.round(1)}s"
    refresh_run.update!(
      status: stopped_on_error ? "failed" : "completed",
      finished_at: Time.current,
      error_message: stopped_on_error ? "Stopped before page #{page + 1}" : nil,
      last_message: stopped_on_error ? "Backfill stopped before page #{page + 1}" : "Backfill complete"
    )
    raise Plex::Client::Error, "Backfill stopped before page #{page + 1}; rerun with PLEX_HISTORY_START_PAGE=#{page + 1}" if stopped_on_error
  rescue StandardError => error
    refresh_run&.update!(
      status: "failed",
      finished_at: Time.current,
      error_message: error.message,
      last_message: "History backfill failed"
    )
    raise
  end

  desc "Record one sample of current Plex playback sessions"
  task sample_now_playing: :environment do
    machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER in .env")
    sessions = Plex::Client.from_env.playback_sessions
    saved_count = PlexNowPlayingSample.record_sessions!(machine_identifier, sessions)
    puts "Now playing sessions: #{sessions.size}"
    puts "Samples saved: #{saved_count}"
  end

  desc "Prune old now playing samples"
  task prune_now_playing_samples: :environment do
    deleted_count = PlexNowPlayingSample.prune!
    puts "Pruned #{deleted_count.to_fs(:delimited)} now playing samples older than #{PlexNowPlayingSample.retention_days} days"
  end

  def history_max_pages
    value = ENV.fetch("PLEX_HISTORY_MAX_PAGES", "all")
    return nil if value.to_s.casecmp("all").zero?

    value.to_i.clamp(1, 10_000)
  end

  def history_viewed_after
    days = ENV["PLEX_HISTORY_DAYS"].presence
    return unless days
    return if days.casecmp("all").zero?

    days.to_i.days.ago
  end

  def history_older_than_window?(history, viewed_after)
    oldest_viewed_at = history.filter_map { |stream| stream[:viewed_at].presence&.to_i }.min
    oldest_viewed_at && oldest_viewed_at < viewed_after.to_i
  end

  def fetch_history_page_with_retries(client, page:, page_size:)
    retries = history_retries
    attempt = 0

    begin
      client.playback_history(size: page_size, offset: page * page_size)
    rescue Plex::Client::Error => error
      attempt += 1
      Rails.logger.warn("[plex.backfill_history] page=#{page + 1} attempt=#{attempt} error=#{error.message}")
      if attempt <= retries
        sleep attempt * 2
        puts "History page #{page + 1} failed: #{error.message}; retry #{attempt}/#{retries}"
        retry
      end

      puts "History page #{page + 1} failed after #{attempt} attempts: #{error.message}"
      nil
    end
  end

  def history_retries
    ENV.fetch("PLEX_HISTORY_RETRIES", "8").to_i.clamp(0, 20)
  end
end
