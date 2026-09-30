class StatusController < ApplicationController
  def index
    load_status
  end

  private

  def load_status
    @machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence
    RefreshRun.mark_stale_active!(@machine_identifier)
    @database_ok = database_ok?
    @latest_snapshot = @machine_identifier ? ShareSnapshot.latest_for(@machine_identifier) : ShareSnapshot.latest_first.first
    @latest_refresh = @machine_identifier ? RefreshRun.latest_for(@machine_identifier) : RefreshRun.latest_first.first
    @last_completed_refresh = refresh_scope.where(status: "completed").latest_first.first
    @active_refresh_run = @machine_identifier ? RefreshRun.active_for(@machine_identifier) : RefreshRun.active.first
    @next_daily_refresh_at = next_daily_refresh_at
    @latest_audit_log = ShareAuditLog.recent.first
    @app_revision = app_revision
    @history_summary = @machine_identifier ? PlexStreamEvent.history_summary(@machine_identifier) : nil
    @last_backfill_refresh = refresh_scope.where(status: "completed", admin_email: "rake:backfill").latest_first.first
    activity_scope = PlexActivitySample.where(machine_identifier: @machine_identifier)
    @activity_sample_count = @machine_identifier ? activity_scope.count : 0
    @latest_activity_sample = @machine_identifier ? activity_scope.recent.first : nil
  end

  def database_ok?
    ActiveRecord::Base.connection.active?
  rescue ActiveRecord::ActiveRecordError
    false
  end

  def app_revision
    ENV["APP_REVISION"].presence ||
      ENV["GIT_SHA"].presence ||
      git_revision.presence ||
      "unknown"
  end

  def refresh_scope
    @machine_identifier ? RefreshRun.where(machine_identifier: @machine_identifier) : RefreshRun.all
  end

  def next_daily_refresh_at
    clock = ENV.fetch("PLEX_DAILY_REFRESH_AT", "04:15")
    return unless clock.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

    hour, minute = clock.split(":", 2).map(&:to_i)
    zone = Time.find_zone(ENV.fetch("TZ", "UTC"))
    return unless zone

    now = zone.now
    target = now.change(hour: hour, min: minute, sec: 0)
    target += 1.day if target <= now
    target
  rescue ArgumentError
    nil
  end

  def git_revision
    return unless Rails.root.join(".git").exist?

    `git rev-parse --short HEAD 2>/dev/null`.strip
  rescue StandardError
    nil
  end
end
