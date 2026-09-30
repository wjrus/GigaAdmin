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
    sample = Plex::ActivityCollector.call

    redirect_to maintenance_path, notice: "Recorded activity: #{helpers.pluralize(sample.total_sessions, "stream")} (one poll per minute)."
  rescue Plex::ConfigurationError, Plex::Client::Error => error
    redirect_to maintenance_path, alert: error.message
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.error("[plex.activity] collection failed (#{error.class})")
    redirect_to maintenance_path, alert: "Activity could not be saved. Check the application logs."
  end

  def prune_now_playing_samples
    deleted_count = PlexActivitySample.prune!

    redirect_to maintenance_path, notice: "Pruned #{helpers.pluralize(deleted_count, "activity poll")}."
  rescue Plex::ConfigurationError => error
    redirect_to maintenance_path, alert: error.message
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.error("[plex.activity] pruning failed (#{error.class})")
    redirect_to maintenance_path, alert: "Activity history could not be pruned. Check the application logs."
  end

  private

  def load_maintenance
    @machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence
    @activity_sample_count = sample_scope.count
    @latest_activity_sample = sample_scope.recent.first
    @oldest_activity_sample = sample_scope.order(:sampled_at).first
    @suppressed_user_count = PlexUserNote.where(suppressed: true).count
    @history_summary = @machine_identifier ? PlexStreamEvent.history_summary(@machine_identifier) : nil
    @activity_retention_days = PlexActivitySample.retention_days
  rescue Plex::ConfigurationError => error
    @activity_configuration_error = error.message
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
    return PlexActivitySample.none if @machine_identifier.blank?

    PlexActivitySample.where(machine_identifier: @machine_identifier)
  end

  def refresh_scope
    @machine_identifier.present? ? RefreshRun.where(machine_identifier: @machine_identifier) : RefreshRun.all
  end
end
