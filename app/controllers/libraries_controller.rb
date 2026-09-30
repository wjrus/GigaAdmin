class LibrariesController < ApplicationController
  defer_page :show, title: "Library"

  def show
    @machine_identifier = required_machine_identifier
    @library_title = params[:library_title].to_s
    @snapshot = ShareSnapshot.latest_for(@machine_identifier)
    @report = @snapshot&.to_report
    @library = library_from_snapshot
    @shared_users = shared_users
    @events = completed_event_scope
    @usage_statistics = Plex::UsageStatistics.new(scope: @events, bucket: "month", sections: %i[summary types users recent]).call
    @event_count = @usage_statistics[:summary][:completed_plays]
    @unique_user_count = @usage_statistics[:summary][:users]
    @type_stats = @usage_statistics[:types].map { |stat| stat.merge(label: stat[:identifier]) }
    @top_users = top_users
    recent_ids = @usage_statistics[:recent].map { |stat| stat[:identifier] }
    @recent_events = PlexStreamEvent.where(id: recent_ids).recent.select(:id, :account_id, :viewed_at, :title, :full_title, :media_type).to_a
    @latest_event = @recent_events.first
    @max_type_plays = @type_stats.map { |stat| stat[:plays] }.max.to_i
    @max_user_plays = @top_users.map { |stat| stat[:plays] }.max.to_i
  rescue Plex::ConfigurationError => error
    @configuration_error = error.message
  rescue ActiveRecord::ActiveRecordError => error
    @plex_error = error.message
  end

  private

  def library_from_snapshot
    (@report&.libraries || []).find { |library| library.title.to_s == @library_title }
  end

  def shared_users
    (@report&.users || []).select do |user|
      user.libraries.any? { |library| library.title.to_s == @library_title }
    end
  end

  def top_users
    labels = user_labels
    @usage_statistics[:users].map do |stat|
      account_id = stat[:identifier]
      stat.merge(account_id: account_id, label: labels.fetch(account_id.to_s, "Account #{account_id}"))
    end
  end

  def user_labels
    account_ids = @usage_statistics[:users].map { |stat| stat[:identifier] }
    labels = PlexUserNote.where(plex_user_id: account_ids).where.not(username: [ nil, "" ]).pluck(:plex_user_id, :username).to_h
    (@report&.users || []).each { |user| labels[user.id.to_s] = user.label }
    labels
  end

  def event_scope
    ids = [ @library&.id, @library&.key ].compact.map(&:to_s)
    PlexStreamEvent
      .where(machine_identifier: @machine_identifier)
      .where("library_title = :title OR metadata->>'library_section_id' IN (:ids)", title: @library_title, ids: ids)
  end

  def completed_event_scope
    return PlexStreamEvent.none unless @library

    PlexStreamEvent.completed_video_play_scope(
      event_scope,
      library_titles: [ @library_title ],
      library_ids: [ @library.id, @library.key ].compact.map(&:to_s)
    )
  end

  def required_machine_identifier
    ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER")
  end
end
