class LibrariesController < ApplicationController
  def show
    @machine_identifier = required_machine_identifier
    @library_title = params[:library_title].to_s
    @snapshot = ShareSnapshot.latest_for(@machine_identifier)
    @library = library_from_snapshot
    @shared_users = shared_users
    @events = completed_event_scope
    @event_count = @events.count
    @unique_user_count = @events.distinct.count(:account_id)
    @latest_event = @events.recent.first
    @type_stats = type_stats
    @top_users = top_users
    @recent_events = @events.recent.limit(50)
    @max_type_plays = @type_stats.map { |stat| stat[:plays] }.max.to_i
    @max_user_plays = @top_users.map { |stat| stat[:plays] }.max.to_i
  rescue Plex::ConfigurationError => error
    @configuration_error = error.message
  rescue ActiveRecord::ActiveRecordError => error
    @plex_error = error.message
  end

  private

  def library_from_snapshot
    (@snapshot&.to_report&.libraries || []).find { |library| library.title.to_s == @library_title }
  end

  def shared_users
    (@snapshot&.to_report&.users || []).select do |user|
      user.libraries.any? { |library| library.title.to_s == @library_title }
    end
  end

  def type_stats
    @events
      .where.not(media_type: [ nil, "" ])
      .group(:media_type)
      .order(Arel.sql("COUNT(*) DESC"))
      .pluck(:media_type, Arel.sql("COUNT(*)"))
      .map { |media_type, plays| { label: media_type, plays: plays } }
  end

  def top_users
    labels = user_labels
    @events
      .group(:account_id)
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(12)
      .pluck(:account_id, Arel.sql("COUNT(*)"), Arel.sql("MAX(viewed_at)"))
      .map do |account_id, plays, latest|
        { account_id: account_id, label: labels.fetch(account_id.to_s, "Account #{account_id}"), plays: plays, latest: latest }
      end
  end

  def user_labels
    labels = PlexUserNote.where.not(username: [ nil, "" ]).pluck(:plex_user_id, :username).to_h
    (@snapshot&.to_report&.users || []).each { |user| labels[user.id.to_s] = user.label }
    labels
  end

  def event_scope
    ids = [ @library&.id, @library&.key ].compact.map(&:to_s)
    PlexStreamEvent
      .where(machine_identifier: @machine_identifier)
      .where("library_title = :title OR metadata->>'library_section_id' IN (:ids)", title: @library_title, ids: ids)
  end

  def completed_event_scope
    return PlexStreamEvent.none unless library_from_snapshot

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
