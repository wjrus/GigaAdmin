class SuppressedUsersController < ApplicationController
  def index
    @machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence
    @suppressed_notes = PlexUserNote.where(suppressed: true).order(suppressed_at: :desc, updated_at: :desc)
    @latest_streams_by_user_id = latest_streams_by_user_id(@suppressed_notes.map(&:plex_user_id))
  end

  private

  def latest_streams_by_user_id(user_ids)
    return {} if @machine_identifier.blank? || user_ids.empty?

    PlexStreamEvent.latest_for_accounts(@machine_identifier, user_ids)
      .index_by { |stream| stream.account_id.to_s }
  end
end
