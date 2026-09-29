class MaintenanceController < ApplicationController
  def index
    load_refresh
    load_maintenance
  end

  def refresh
    load_refresh
    render partial: "refresh_panel"
  end

  def sample_now_playing
    machine_identifier = required_machine_identifier
    sessions = Plex::Client.from_env.playback_sessions
    saved_count = PlexNowPlayingSample.record_sessions!(machine_identifier, sessions)

    redirect_to maintenance_path, notice: "Sampled #{helpers.pluralize(saved_count, "active stream")}."
  rescue Plex::ConfigurationError, Plex::Client::Error, ActiveRecord::ActiveRecordError => error
    redirect_to maintenance_path, alert: error.message
  end

  def prune_now_playing_samples
    deleted_count = PlexNowPlayingSample.prune!

    redirect_to maintenance_path, notice: "Pruned #{helpers.pluralize(deleted_count, "now playing sample")}."
  rescue ActiveRecord::ActiveRecordError => error
    redirect_to maintenance_path, alert: error.message
  end

  private

  def load_maintenance
    @machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence
    @now_playing_sample_count = sample_scope.count
    @latest_now_playing_sample = sample_scope.recent.first
    @oldest_now_playing_sample = sample_scope.order(:sampled_at).first
    @retention_days = PlexNowPlayingSample.retention_days
    @suppressed_user_count = PlexUserNote.where(suppressed: true).count
    @history_summary = @machine_identifier ? PlexStreamEvent.history_summary(@machine_identifier) : nil
  end

  def load_refresh
    @machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence
    RefreshRun.mark_stale_active!(@machine_identifier)
    @latest_refresh = refresh_scope.latest_first.first
    @active_refresh_run = refresh_scope.active.latest_first.first
    @last_completed_refresh = refresh_scope.where(status: "completed").latest_first.first
    @latest_snapshot = @machine_identifier ? ShareSnapshot.latest_for(@machine_identifier) : ShareSnapshot.latest_first.first
  end

  def sample_scope
    return PlexNowPlayingSample.none if @machine_identifier.blank?

    PlexNowPlayingSample.where(machine_identifier: @machine_identifier)
  end

  def refresh_scope
    @machine_identifier.present? ? RefreshRun.where(machine_identifier: @machine_identifier) : RefreshRun.all
  end

  def required_machine_identifier
    ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
      raise(Plex::ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER")
  end
end
