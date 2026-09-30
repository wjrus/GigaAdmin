require "test_helper"

class PlexRefreshJobTest < ActiveSupport::TestCase
  test "redelivery of a completed refresh does not restart history or replace its status" do
    run = RefreshRun.create!(machine_identifier: "completed-job", status: "completed", finished_at: 1.hour.ago,
      history_pages_retrieved: 12, last_message: "Saved snapshot")
    original = Plex::Client.method(:from_env)
    Plex::Client.define_singleton_method(:from_env) { raise "Completed refresh must not contact Plex" }

    assert_no_changes -> { run.reload.attributes } do
      PlexRefreshJob.new.perform(run.id)
    end
  ensure
    Plex::Client.define_singleton_method(:from_env, original)
  end
end
