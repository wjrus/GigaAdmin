class StatsController < ApplicationController
  PERIOD_OPTIONS = {
    "24h" => { label: "Last day", duration: 24.hours },
    "7d" => { label: "Last week", duration: 168.hours },
    "30d" => { label: "Last month", duration: 720.hours },
    "90d" => { label: "Last 3 months", duration: 2160.hours },
    "180d" => { label: "Last 6 months", duration: 4320.hours },
    "1y" => { label: "Last year", duration: 8760.hours },
    "all" => { label: "All time" }
  }.freeze

  MOVIE_IDENTITY_SQL = <<~SQL.squish.freeze
    COALESCE('id:' || NULLIF(rating_key, ''),
      'title:' || COALESCE(NULLIF(title, ''), NULLIF(full_title, '')),
      'event:' || id::text)
  SQL
  SHOW_IDENTITY_SQL = <<~SQL.squish.freeze
    COALESCE('id:' || NULLIF(metadata->>'grandparent_rating_key', ''),
      'title:' || COALESCE(NULLIF(metadata->>'grandparent_title', ''), NULLIF(split_part(full_title, ' - ', 1), '')),
      'episode:' || NULLIF(rating_key, ''), 'event:' || id::text)
  SQL

  def index
    @machine_identifier = required_machine_identifier
    @live_activity = Plex::ActivityChart.new(machine_identifier: @machine_identifier, period: params[:activity_period])
    @stats_period = params[:period].presence_in(PERIOD_OPTIONS.keys) || "7d"
    @stats_period_options = PERIOD_OPTIONS.transform_values { |option| option[:label] }
    @stats_period_label = @stats_period_options.fetch(@stats_period)
    @stats_period_end = Time.current
    duration = PERIOD_OPTIONS.fetch(@stats_period)[:duration]
    @stats_period_start = @stats_period_end - duration if duration
    @active_libraries = active_libraries
    @active_library_titles = @active_libraries.map(&:title)
    @active_library_ids = @active_libraries.flat_map { |library| [ library.id, library.key ] }.compact.map(&:to_s)
    @library_labels_by_identifier = library_labels_by_identifier
    @period_summary = period_summary
    @library_stats = library_stats
    @type_stats = type_stats
    @activity_stats = activity_stats
    @top_users = top_users
    @top_movies = top_titles(media_type: "movie", identity_sql: MOVIE_IDENTITY_SQL)
    @top_shows = top_titles(media_type: "episode", identity_sql: SHOW_IDENTITY_SQL)
    @max_library_plays = @library_stats.map { |stat| stat[:plays] }.max.to_i
    @max_type_plays = @type_stats.map { |stat| stat[:plays] }.max.to_i
    @max_activity_plays = @activity_stats.map { |stat| stat[:plays] }.max.to_i
    @max_user_plays = @top_users.map { |stat| stat[:plays] }.max.to_i
    @max_movie_plays = @top_movies.map { |stat| stat[:plays] }.max.to_i
    @max_show_plays = @top_shows.map { |stat| stat[:plays] }.max.to_i
  rescue Plex::ConfigurationError => error
    @configuration_error = error.message
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.error("[plex.stats] unavailable (#{error.class})")
    @plex_error = "Statistics are temporarily unavailable."
  end

  private

  def period_summary
    count, oldest, newest = completed_event_scope.pick(Arel.sql("COUNT(*)"), Arel.sql("MIN(viewed_at)"), Arel.sql("MAX(viewed_at)"))
    {
      completed_plays: count,
      oldest: oldest,
      newest: newest
    }
  end

  def library_stats
    identifier = Arel.sql(PlexStreamEvent::LIBRARY_IDENTIFIER_SQL)
    completed_event_scope
      .group(identifier)
      .pluck(identifier, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT account_id)"), Arel.sql("MAX(viewed_at)"))
      .map do |key, plays, users, latest|
        { label: @library_labels_by_identifier.fetch(key.to_s, key.to_s), plays: plays, users: users, latest: latest }
      end
      .sort_by { |stat| [ -stat[:plays], stat[:label].downcase ] }
      .first(12)
  end

  def type_stats
    completed_event_scope
      .where.not(media_type: [ nil, "" ])
      .group(:media_type)
      .order(Arel.sql("COUNT(*) DESC"))
      .pluck(:media_type, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT account_id)"))
      .map do |media_type, plays, users|
        { label: media_type, plays: plays, users: users }
      end
  end

  def activity_stats
    if @stats_period.in?(%w[24h 7d 30d])
      daily_activity_stats
    else
      monthly_activity_stats
    end
  end

  def daily_activity_stats
    counts_by_day = PlexStreamEvent.activity_counts(completed_event_scope, bucket: "day")

    (@stats_period_start.to_date..@stats_period_end.to_date).map do |day|
      { label: day.strftime("%b %-d"), plays: counts_by_day.fetch(day, 0) }
    end
  end

  def monthly_activity_stats
    scope = completed_event_scope
    start_time = @stats_period_start || scope.minimum(:viewed_at)&.beginning_of_month || @stats_period_end.beginning_of_month
    end_time = @stats_period_end.beginning_of_month
    counts_by_month = PlexStreamEvent.activity_counts(scope, bucket: "month")

    months = []
    cursor = start_time.beginning_of_month
    while cursor <= end_time
      months << cursor
      cursor += 1.month
    end

    months.map do |month|
      { label: month.strftime("%b %Y"), plays: counts_by_month.fetch(month.to_date, 0) }
    end
  end

  def top_users
    label_by_account_id = user_labels
    completed_event_scope
      .group(:account_id)
      .order(Arel.sql("COUNT(*) DESC"), :account_id)
      .limit(10)
      .pluck(:account_id, Arel.sql("COUNT(*)"), Arel.sql("MAX(viewed_at)"))
      .map do |account_id, plays, latest|
        { account_id: account_id, label: label_by_account_id.fetch(account_id.to_s, "Account #{account_id}"), plays: plays, latest: latest }
      end
  end

  def top_titles(media_type:, identity_sql:)
    identity = Arel.sql(identity_sql)
    label = Arel.sql("MIN(#{PlexStreamEvent::AGGREGATE_TITLE_SQL})")
    completed_event_scope.where(media_type: media_type)
      .group(identity)
      .order(Arel.sql("COUNT(*) DESC"), label, identity)
      .limit(10)
      .pluck(label, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT account_id)"))
      .map { |title, plays, users| { label: title, plays: plays, users: users } }
  end

  def active_libraries
    Array(sharing_report&.libraries)
  end

  def library_labels_by_identifier
    @active_libraries.each_with_object({}) do |library, labels|
      labels[library.title.to_s] = library.title
      labels[library.id.to_s] = library.title if library.id.present?
      labels[library.key.to_s] = library.title if library.key.present?
    end
  end

  def user_labels
    labels = PlexUserNote.where.not(username: [ nil, "" ]).pluck(:plex_user_id, :username).to_h
    (sharing_report&.users || []).each do |user|
      labels[user.id.to_s] = user.label
    end
    if ENV["PLEX_OWNER_ACCOUNT_ID"].present?
      labels[ENV["PLEX_OWNER_ACCOUNT_ID"].to_s] =
        ENV["PLEX_OWNER_USERNAME"].presence ||
        ENV["PLEX_OWNER_NAME"].presence ||
        ENV["PLEX_OWNER_EMAIL"].presence ||
        "Server owner"
    end
    labels
  end

  def event_scope
    PlexStreamEvent.where(machine_identifier: @machine_identifier).where("viewed_at <= ?", @stats_period_end)
  end

  def sharing_report
    return @sharing_report if defined?(@sharing_report)

    @sharing_report = ShareSnapshot.latest_for(@machine_identifier)&.to_report
  end

  def completed_event_scope
    PlexStreamEvent.completed_video_play_scope(event_scope, library_titles: @active_library_titles,
      library_ids: @active_library_ids, since: @stats_period_start)
  end

  def required_machine_identifier
    ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER")
  end
end
