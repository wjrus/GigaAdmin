require "test_helper"

class PrunePlexActivityJobTest < ActiveSupport::TestCase
  test "prunes aggregate retention without touching legacy samples or playback history" do
    previous = ENV["PLEX_ACTIVITY_RETENTION_DAYS"]
    ENV["PLEX_ACTIVITY_RETENTION_DAYS"] = "90"
    PlexActivitySample.record_sessions!("prune-job", [], sampled_at: 91.days.ago)
    recent = PlexActivitySample.record_sessions!("prune-job", [], sampled_at: Time.current)
    legacy = PlexNowPlayingSample.create!(machine_identifier: "prune-job", sampled_at: 200.days.ago)
    history = PlexStreamEvent.create!(machine_identifier: "prune-job", account_id: "viewer", viewed_at: 200.days.ago)

    assert_difference "PlexActivitySample.count", -1 do
      PrunePlexActivityJob.new.perform
    end
    assert PlexActivitySample.exists?(recent.id)
    assert PlexNowPlayingSample.exists?(legacy.id)
    assert PlexStreamEvent.exists?(history.id)
  ensure
    ENV["PLEX_ACTIVITY_RETENTION_DAYS"] = previous
  end
end
