class PlexRefreshJob < ApplicationJob
  queue_as :default

  def perform(refresh_run_id)
    refresh_run = RefreshRun.find(refresh_run_id)
    return if refresh_run.status == "completed"

    refresh_run.update!(
      status: "running",
      started_at: Time.current,
      finished_at: nil,
      error_message: nil,
      share_snapshot_id: nil,
      history_pages_retrieved: 0,
      history_rows_retrieved: 0,
      history_users_matched: 0,
      history_users_remaining: 0,
      account_lookups_completed: 0,
      account_lookups_total: 0,
      last_message: "Refresh started"
    )
    Rails.logger.info("[plex.refresh] run=#{refresh_run.id} status=running history=#{refresh_run.include_history}")

    snapshot = Plex::SnapshotRefresh.new(
      client: Plex::Client.from_env,
      machine_identifier: refresh_run.machine_identifier,
      include_history: refresh_run.include_history,
      progress: Plex::RefreshProgressRecorder.new(refresh_run)
    ).call

    refresh_run.update!(
      status: "completed",
      share_snapshot_id: snapshot.id,
      finished_at: Time.current,
      last_message: "Saved snapshot ##{snapshot.id}"
    )
    Rails.logger.info("[plex.refresh] run=#{refresh_run.id} status=completed snapshot=#{snapshot.id}")
  rescue StandardError => error
    refresh_run&.update!(
      status: "failed",
      finished_at: Time.current,
      error_message: error.message,
      last_message: "Refresh failed"
    )
    Rails.logger.error("[plex.refresh] run=#{refresh_run&.id || refresh_run_id} status=failed error=#{error.class}: #{error.message}")
    raise
  end
end
