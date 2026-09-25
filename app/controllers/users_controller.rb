class UsersController < ApplicationController
  require "csv"
  require "set"

  SORT_COLUMNS = %w[name last_streamed].freeze
  SORT_DIRECTIONS = %w[asc desc].freeze
  STATS_PERIOD_OPTIONS = {
    "7d" => { label: "7 days", start: -> { 6.days.ago.beginning_of_day } },
    "30d" => { label: "30 days", start: -> { 29.days.ago.beginning_of_day } },
    "1y" => { label: "Past year", start: -> { 11.months.ago.beginning_of_month } },
    "all" => { label: "All time", start: -> { nil } }
  }.freeze
  helper_method :local_history_user?, :suppressed_user?

  def index
    @machine_identifier = required_machine_identifier
    @snapshot = ShareSnapshot.latest_for(@machine_identifier)
    @sort = params[:sort].presence_in(SORT_COLUMNS) || "name"
    @direction = params[:direction].presence_in(SORT_DIRECTIONS) || default_direction_for(@sort)
    @report = @snapshot&.to_report
    @libraries = @report&.libraries || []
    @active_library_titles = @libraries.map(&:title)
    @active_library_ids = @libraries.flat_map { |library| [ library.id, library.key ] }.compact.map(&:to_s)
    @filter_params = filter_params
    @all_users = users_with_local_stream_accounts(@report&.users || [], include_suppressed: showing_suppressed?)
    @notes_by_user_id = PlexUserNote.for_users(@all_users)
    @pending_users = @all_users.select(&:pending)
    @suppressed_user_count = PlexUserNote.where(suppressed: true).count
    @users = sort_users(filter_users(@all_users))
    @audit_counts_by_user_id = audit_counts_for(@users)

    respond_to do |format|
      format.html
      format.csv do
        send_data users_csv(@users),
          filename: "plex-users-#{Time.zone.today}.csv",
          type: "text/csv"
      end
    end
  rescue Plex::ConfigurationError => error
    @configuration_error = error.message
  rescue ActiveRecord::ActiveRecordError => error
    @plex_error = error.message
  end

  def show
    @machine_identifier = required_machine_identifier
    @snapshot = ShareSnapshot.latest_for(@machine_identifier)
    @report = @snapshot&.to_report
    @libraries = @report&.libraries || []
    @active_library_titles = @libraries.map(&:title)
    @active_library_ids = @libraries.flat_map { |library| [ library.id, library.key ] }.compact.map(&:to_s)
    @all_users = users_with_local_stream_accounts(@report&.users || [], include_suppressed: true)
    @notes_by_user_id = PlexUserNote.for_users(@all_users)
    @user = resolve_user(params[:plex_user_id])
    @user ||= cache_pending_invite_for(params[:plex_user_id])
    raise ActiveRecord::RecordNotFound, "Unknown Plex user" unless @user

    load_stats_period
    @note = PlexUserNote.find_by(plex_user_id: @user.id.to_s)
    load_stream_history
    load_user_stream_stats
    load_user_stream_charts
    load_now_playing_samples
    @audit_logs = ShareAuditLog.where(plex_user_id: @user.id.to_s).recent.limit(50)
    respond_to do |format|
      format.html
      format.csv do
        send_data stream_history_csv,
          filename: "plex-stream-history-#{@user.id}-#{Time.zone.today}.csv",
          type: "text/csv"
      end
    end
  rescue Plex::ConfigurationError => error
    @configuration_error = error.message
  rescue ActiveRecord::ActiveRecordError => error
    @plex_error = error.message
  end

  def update_note
    note = PlexUserNote.find_or_initialize_by(plex_user_id: params[:plex_user_id])
    note.assign_attributes(note_params.merge(last_edited_by: current_admin_email))
    PlexUserNote.transaction do
      note.save!
      record_note_update(note) if note.saved_change_to_notes?
    end

    redirect_to note_redirect_path, notice: "User note saved."
  rescue ActiveRecord::ActiveRecordError => error
    redirect_to users_path, alert: error.message
  end

  def update_suppression
    @machine_identifier = required_machine_identifier
    @snapshot = ShareSnapshot.latest_for(@machine_identifier)
    @report = @snapshot&.to_report
    @user = users_with_local_stream_accounts(@report&.users || [], include_suppressed: true)
      .find { |user| user.id.to_s == params[:plex_user_id].to_s }
    note = PlexUserNote.find_or_initialize_by(plex_user_id: params[:plex_user_id])
    suppressing = truthy_param?(params[:suppressed])
    note.assign_attributes(
      username: note.username.presence || @user&.username,
      email: note.email.presence || @user&.email,
      suppressed: suppressing,
      suppressed_at: suppressing ? Time.current : nil,
      suppressed_by: suppressing ? current_admin_email : nil
    )
    PlexUserNote.transaction do
      note.save!
      record_suppression_update(note, suppressing)
    end

    redirect_to suppression_redirect_path, notice: suppressing ? "User suppressed." : "User unsuppressed."
  rescue ActiveRecord::ActiveRecordError => error
    redirect_to users_path, alert: error.message
  end

  private

  def note_params
    params.require(:plex_user_note).permit(:username, :email, :notes)
  end

  def truthy_param?(value)
    value == true || value.to_s == "1" || value.to_s.casecmp("true").zero?
  end

  def resolve_user(identifier)
    requested = identifier.to_s.downcase
    @all_users.find do |user|
      user_identifiers(user).any? { |value| value.to_s.downcase == requested }
    end
  end

  def user_identifiers(user)
    [
      user.id,
      user.email,
      user.username,
      user.title,
      user.label
    ].compact_blank
  end

  def cache_pending_invite_for(identifier)
    ShareSnapshot.with_server_lock(@machine_identifier) { lookup_pending_invite(identifier) }
  end

  def lookup_pending_invite(identifier)
    @snapshot = ShareSnapshot.latest_for(@machine_identifier)
    requested = identifier.to_s.downcase
    return unless requested.include?("@") && @snapshot

    invite = Plex::Client.from_env.requested_invites.find do |candidate|
      user_identifiers_for_invite(candidate).any? { |value| value.to_s.downcase == requested }
    end
    return unless invite && invite[:id].present?

    invite_server = pending_invite_server(invite)
    pending_user = pending_user_row(invite, invite_server)
    @snapshot = ShareSnapshot.create!(
      machine_identifier: @snapshot.machine_identifier,
      server: @snapshot.server,
      libraries: @snapshot.libraries,
      users: @snapshot.users.reject { |user| user["id"].to_s == pending_user["id"].to_s } + [ pending_user ],
      fetched_at: Time.current
    )
    @report = @snapshot.to_report
    @libraries = @report.libraries
    @active_library_titles = @libraries.map(&:title)
    @active_library_ids = @libraries.flat_map { |library| [ library.id, library.key ] }.compact.map(&:to_s)
    @all_users = users_with_local_stream_accounts(@report.users, include_suppressed: true)
    @notes_by_user_id = PlexUserNote.for_users(@all_users)
    resolve_user(pending_user["id"]) || resolve_user(identifier)
  rescue Plex::Client::Error => error
    Rails.logger.warn("[plex.invites] lookup #{identifier}: #{error.message}")
    nil
  end

  def user_identifiers_for_invite(invite)
    [
      invite[:id],
      invite[:email],
      invite[:username],
      invite[:friendly_name],
      invite[:title]
    ].compact_blank
  end

  def pending_invite_server(invite)
    server_id = @snapshot.server["id"].to_s
    server_name = @snapshot.server["name"].to_s
    Array(invite[:servers]).find do |candidate|
      candidate[:machine_identifier].to_s == @machine_identifier ||
        candidate[:client_identifier].to_s == @machine_identifier ||
        candidate[:id].to_s == server_id ||
        candidate[:name].to_s == server_name
    end
  end

  def pending_user_row(invite, invite_server)
    library_count = invite_server&.[](:num_libraries).to_i
    all_libraries = @snapshot.libraries
    libraries = library_count == all_libraries.size ? all_libraries : []

    {
      "id" => invite[:id],
      "share_id" => nil,
      "title" => invite[:friendly_name].presence || invite[:username].presence || invite[:email],
      "username" => invite[:username],
      "email" => invite[:email],
      "thumb" => invite[:thumb],
      "home" => truthy_param?(invite[:home]),
      "restricted" => false,
      "allow_sync" => false,
      "allow_channels" => false,
      "last_seen_at" => nil,
      "last_streamed_at" => nil,
      "last_streamed_title" => nil,
      "last_streamed_type" => nil,
      "invited_at" => invite[:created_at].presence || Time.current.to_i.to_s,
      "invite_friend" => truthy_param?(invite[:friend]),
      "invite_server" => truthy_param?(invite[:server]) || invite_server.present?,
      "pending" => true,
      "all_libraries" => libraries.any? && libraries.size == all_libraries.size,
      "library_count" => library_count.positive? ? library_count : libraries.size,
      "libraries" => libraries
    }
  end

  def load_stream_history
    @stream_per_page = 25
    @stream_page = params.fetch(:stream_page, "1").to_i.clamp(1, 100_000)
    @stream_filter_params = stream_filter_params
    @stream_type_options = stream_scope.where.not(media_type: [ nil, "" ]).distinct.order(:media_type).pluck(:media_type)
    @stream_filters_active = @stream_filter_params.to_h.values.any?(&:present?)
    scope = filtered_stream_scope.recent
    @stream_events_count = scope.count
    @stream_total_pages = [ (@stream_events_count.to_f / @stream_per_page).ceil, 1 ].max
    @stream_page = [ @stream_page, @stream_total_pages ].min
    @stream_offset = (@stream_page - 1) * @stream_per_page
    @stream_events = scope.offset(@stream_offset).limit(@stream_per_page)
    @stream_has_player_data = scope.where.not(player_title: [ nil, "" ]).or(scope.where.not(player_platform: [ nil, "" ])).exists?
    @stream_has_ip_data = scope.where.not(ip_address: [ nil, "" ]).exists?
    @stream_page_start = @stream_events_count.zero? ? 0 : @stream_offset + 1
    @stream_page_end = [ @stream_offset + @stream_events.size, @stream_events_count ].min
  end

  def load_user_stream_stats
    scope = completed_stream_scope
    total, first, last = scope.pick(Arel.sql("COUNT(*)"), Arel.sql("MIN(viewed_at)"), Arel.sql("MAX(viewed_at)"))
    @stream_stats = {
      total: total,
      first: first,
      last: last,
      top_type: top_group_value(scope, :media_type),
      top_library: top_group_value(scope, :library_title)
    }
  end

  def load_stats_period
    @stats_period = params[:period].presence_in(STATS_PERIOD_OPTIONS.keys) || "7d"
    @stats_period_options = STATS_PERIOD_OPTIONS.transform_values { |option| option[:label] }
    @stats_period_label = @stats_period_options.fetch(@stats_period)
    @stats_period_start = STATS_PERIOD_OPTIONS.fetch(@stats_period)[:start].call
  end

  def stream_scope
    PlexStreamEvent.where(machine_identifier: @machine_identifier, account_id: @user.id.to_s)
  end

  def completed_stream_scope
    PlexStreamEvent.completed_video_play_scope(stream_scope, library_titles: @active_library_titles,
      library_ids: @active_library_ids, since: @stats_period_start)
  end

  def filtered_stream_scope
    scope = stream_scope
    query = @stream_filter_params[:stream_q].to_s.strip.downcase
    if query.present?
      escaped_query = ActiveRecord::Base.sanitize_sql_like(query)
      scope = scope.where(
        "LOWER(COALESCE(full_title, '') || ' ' || COALESCE(title, '') || ' ' || COALESCE(library_title, '') || ' ' || COALESCE(rating_key, '')) LIKE ?",
        "%#{escaped_query}%"
      )
    end
    scope = scope.where(media_type: @stream_filter_params[:stream_type]) if @stream_filter_params[:stream_type].present?
    scope = scope.where("viewed_at >= ?", parsed_stream_date(@stream_filter_params[:stream_from])&.beginning_of_day) if parsed_stream_date(@stream_filter_params[:stream_from])
    scope = scope.where("viewed_at <= ?", parsed_stream_date(@stream_filter_params[:stream_to])&.end_of_day) if parsed_stream_date(@stream_filter_params[:stream_to])
    scope
  end

  def stream_filter_params
    params.permit(:stream_q, :stream_type, :stream_from, :stream_to)
  end

  def stream_query_params(extra = {})
    @stream_filter_params.to_h.merge(extra).compact_blank
  end
  helper_method :stream_query_params

  def parsed_stream_date(value)
    return if value.blank?

    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def load_user_stream_charts
    scope = completed_stream_scope
    @stream_activity_stats = user_activity_stats(scope)
    @stream_type_stats = scope
      .where.not(media_type: [ nil, "" ])
      .group(:media_type)
      .order(Arel.sql("COUNT(*) DESC"))
      .pluck(:media_type, Arel.sql("COUNT(*)"))
      .map { |media_type, plays| { label: media_type, plays: plays } }
    @stream_top_series = aggregate_title_stats(scope.where(media_type: "episode"), limit: 8)
    @stream_top_movies = aggregate_title_stats(scope.where(media_type: "movie"), limit: 8)
    @max_stream_activity_plays = @stream_activity_stats.map { |stat| stat[:plays] }.max.to_i
    @max_stream_type_plays = @stream_type_stats.map { |stat| stat[:plays] }.max.to_i
    @max_stream_series_plays = @stream_top_series.map { |stat| stat[:plays] }.max.to_i
    @max_stream_movie_plays = @stream_top_movies.map { |stat| stat[:plays] }.max.to_i
  end

  def load_now_playing_samples
    @now_playing_samples = PlexNowPlayingSample
      .where(machine_identifier: @machine_identifier)
      .where("account_id = :account_id OR user_label = :label", account_id: @user.id.to_s, label: @user.label)
      .recent
      .limit(12)
  end

  def user_activity_stats(scope)
    if @stats_period.in?(%w[7d 30d])
      user_daily_stats(scope)
    else
      user_monthly_stats(scope)
    end
  end

  def user_daily_stats(scope)
    days = @stats_period == "30d" ? 30 : 7
    counts_by_day = PlexStreamEvent.activity_counts(scope, bucket: "day")

    (days - 1).downto(0).map do |days_ago|
      day = days_ago.days.ago.to_date
      { label: day.strftime("%b %-d"), plays: counts_by_day.fetch(day, 0) }
    end
  end

  def user_monthly_stats(scope)
    start_time = @stats_period_start || scope.minimum(:viewed_at)&.beginning_of_month || Time.current.beginning_of_month
    end_time = Time.current.beginning_of_month
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

  def aggregate_title_stats(scope, limit:)
    title = Arel.sql(PlexStreamEvent::AGGREGATE_TITLE_SQL)
    scope
      .group(title)
      .order(Arel.sql("COUNT(*) DESC, LOWER(#{PlexStreamEvent::AGGREGATE_TITLE_SQL}) ASC"))
      .limit(limit)
      .pluck(title, Arel.sql("COUNT(*)"), Arel.sql("MAX(viewed_at)"))
      .map { |label, plays, latest| { label: label, plays: plays, latest: latest } }
  end

  def top_group_value(scope, column)
    value, count = scope.where.not(column => [ nil, "" ]).group(column).count.max_by { |_value, grouped_count| grouped_count }
    value ? "#{value} (#{count})" : "Unknown"
  end

  def record_note_update(note)
    ShareAuditLog.record!(
      action: "user_note_updated",
      admin_email: current_admin_email,
      target: {
        id: note.plex_user_id,
        label: note.username.presence || note.email.presence || note.plex_user_id,
        email: note.email
      }
    )
  end

  def record_suppression_update(note, suppressing)
    ShareAuditLog.record!(
      action: suppressing ? "user_suppressed" : "user_unsuppressed",
      admin_email: current_admin_email,
      target: {
        id: note.plex_user_id,
        label: note.username.presence || note.email.presence || note.plex_user_id,
        email: note.email
      }
    )
  end

  def note_redirect_path
    url_from(params[:return_to]) || users_path(filter_params.merge(sort: params[:sort], direction: params[:direction]))
  end

  def suppression_redirect_path
    url_from(params[:return_to]) || user_path(params[:plex_user_id])
  end

  def required_machine_identifier
    ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER in .env")
  end

  def sort_users(users)
    sorted_users = users.sort_by { |user| sort_key_for(user) }
    @direction == "desc" ? sorted_users.reverse : sorted_users
  end

  def filter_params
    params.permit(:q, :status, :library_id, :notes, :streaming)
  end

  def showing_suppressed?
    @filter_params[:status].to_s == "suppressed"
  end

  def filter_users(users)
    users.select do |user|
      matches_search?(user) &&
        matches_status?(user) &&
        matches_library?(user) &&
        matches_notes?(user) &&
        matches_streaming?(user)
    end
  end

  def audit_counts_for(users)
    ShareAuditLog
      .where(plex_user_id: users.map { |user| user.id.to_s })
      .group(:plex_user_id)
      .count
  end

  def users_with_local_stream_accounts(users, include_suppressed:)
    users + local_stream_users(excluding: users, include_suppressed: include_suppressed)
  end

  def local_stream_users(excluding:, include_suppressed:)
    excluded_ids = excluding.map { |user| user.id.to_s }.to_set
    suppressed_ids = PlexUserNote.suppressed_ids
    newest_stream_by_account_id(excluded_ids).filter_map do |account_id, stream|
      suppressed = suppressed_ids.include?(account_id.to_s)
      next if suppressed && !include_suppressed

      Plex::SharingReport::SharedUser.new(
        id: account_id,
        share_id: nil,
        title: local_stream_account_title(account_id),
        username: local_stream_account_username(account_id),
        email: local_stream_account_email(account_id),
        thumb: nil,
        home: false,
        restricted: false,
        allow_sync: false,
        allow_channels: false,
        last_seen_at: nil,
        last_streamed_at: stream.viewed_at.to_i,
        last_streamed_title: stream.label,
        last_streamed_type: stream.media_type,
        invited_at: nil,
        invite_friend: nil,
        invite_server: nil,
        pending: false,
        all_libraries: false,
        library_count: 0,
        libraries: []
      )
    end
  end

  def newest_stream_by_account_id(excluded_ids)
    PlexStreamEvent
      .where(machine_identifier: @machine_identifier)
      .where.not(account_id: excluded_ids.to_a)
      .latest_per_account
      .index_by { |stream| stream.account_id.to_s }
  end

  def local_stream_account_title(account_id)
    return ENV["PLEX_OWNER_NAME"].presence if owner_account?(account_id)

    "Account #{account_id}"
  end

  def local_stream_account_username(account_id)
    return ENV["PLEX_OWNER_USERNAME"].presence if owner_account?(account_id)

    nil
  end

  def local_stream_account_email(account_id)
    return ENV["PLEX_OWNER_EMAIL"].presence if owner_account?(account_id)

    nil
  end

  def owner_account?(account_id)
    ENV["PLEX_OWNER_ACCOUNT_ID"].present? && ENV["PLEX_OWNER_ACCOUNT_ID"].to_s == account_id.to_s
  end

  def users_csv(users)
    CSV.generate(headers: true) do |csv|
      csv << [ "name", "username", "email", "status", "last_streamed_at", "last_streamed_title", "libraries", "library_count", "has_notes", "audit_events" ]
      users.each do |user|
        note = @notes_by_user_id[user.id.to_s]
        csv << CsvSafety.row([
          user.label,
          user.username,
          user.email,
          user_status(user),
          user.last_streamed_at.present? ? Time.zone.at(user.last_streamed_at.to_i).iso8601 : nil,
          user.last_streamed_title,
          user.libraries.map(&:title).to_sentence,
          user.libraries.size,
          note&.notes.present?,
          @audit_counts_by_user_id.fetch(user.id.to_s, 0)
        ])
      end
    end
  end

  def stream_history_csv
    CSV.generate(headers: true) do |csv|
      csv << [ "viewed_at", "title", "type", "library", "player", "ip_address", "rating_key" ]
      filtered_stream_scope.recent.each do |event|
        csv << CsvSafety.row([
          event.viewed_at.iso8601,
          event.label,
          event.media_type,
          event.library_title,
          event.player_label == "Unknown" ? nil : event.player_label,
          event.ip_address,
          event.rating_key
        ])
      end
    end
  end

  def matches_search?(user)
    query = @filter_params[:q].to_s.strip.downcase
    return true if query.blank?

    [ user.label, user.username, user.email ].compact.any? { |value| value.downcase.include?(query) }
  end

  def matches_status?(user)
    case @filter_params[:status]
    when "pending"
      user.pending
    when "accepted"
      !user.pending && !local_history_user?(user)
    when "suppressed"
      suppressed_user?(user)
    else
      !suppressed_user?(user)
    end
  end

  def matches_library?(user)
    library_id = @filter_params[:library_id].to_s
    return true if library_id.blank?

    user.libraries.any? { |library| library.id.to_s == library_id }
  end

  def matches_notes?(user)
    case @filter_params[:notes]
    when "with"
      @notes_by_user_id[user.id.to_s]&.notes.present?
    when "without"
      @notes_by_user_id[user.id.to_s]&.notes.blank?
    else
      true
    end
  end

  def matches_streaming?(user)
    case @filter_params[:streaming]
    when "streamed"
      user.last_streamed_at.present?
    when "never"
      user.last_streamed_at.blank?
    else
      true
    end
  end

  def sort_key_for(user)
    case @sort
    when "last_streamed"
      [
        user.last_streamed_at.present? ? 0 : 1,
        user.last_streamed_at.to_i,
        user.label.downcase
      ]
    else
      [ user.label.downcase, user.username.to_s.downcase ]
    end
  end

  def default_direction_for(sort)
    sort == "last_streamed" ? "desc" : "asc"
  end

  def local_history_user?(user)
    !user.pending && user.share_id.blank? && user.libraries.empty? && user.last_streamed_at.present?
  end

  def suppressed_user?(user)
    @notes_by_user_id[user.id.to_s]&.suppressed?
  end

  def user_status(user)
    return "pending" if user.pending
    return "local_history" if local_history_user?(user)

    "accepted"
  end
end
