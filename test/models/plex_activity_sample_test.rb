require "test_helper"

class PlexActivitySampleTest < ActiveSupport::TestCase
  setup do
    @previous_env = ENV.to_h.slice("PLEX_ACTIVITY_ENABLED", "PLEX_ACTIVITY_RETENTION_DAYS")
    ENV.delete("PLEX_ACTIVITY_ENABLED")
    ENV.delete("PLEX_ACTIVITY_RETENTION_DAYS")
  end

  teardown do
    %w[PLEX_ACTIVITY_ENABLED PLEX_ACTIVITY_RETENTION_DAYS].each { |key| ENV[key] = @previous_env[key] }
  end

  test "records only aggregate playback counts with selected media and partial bandwidth" do
    sessions = [
      { user: { title: "Private viewer" }, title: "Private title", player: { state: "playing", address: "192.0.2.1" },
        session: { bandwidth: "12000" }, media: { video_decision: "directplay", audio_decision: "directplay" } },
      { player: { state: "PLAYING" }, session: { bandwidth: "8000" },
        transcode_session: { video_decision: "copy", audio_decision: "transcode" } },
      { player: { state: "paused" }, session: { bandwidth: nil },
        media: [ { selected: "0", video_decision: "transcode" }, { selected: "1", part: [ { decision: "copy" } ] } ] },
      { player: { state: "buffering" }, session: { bandwidth: "unknown" } }
    ]

    sample = PlexActivitySample.record_sessions!("aggregate-machine", sessions)

    assert_equal 4, sample.total_sessions
    assert_equal 2, sample.playing_sessions
    assert_equal 1, sample.paused_sessions
    assert_equal 1, sample.transcode_sessions
    assert_equal 1, sample.direct_play_sessions
    assert_equal 1, sample.direct_stream_sessions
    assert_equal 1, sample.unknown_sessions
    assert_equal 2, sample.bandwidth_sessions
    assert_equal 20_000, sample.bandwidth_kbps
    assert_not_includes sample.attributes.to_json, "Private"
    assert_not_includes sample.attributes.to_json, "192.0.2.1"
  end

  test "a successful empty poll records known zero activity and ignores invalid bandwidth" do
    idle = PlexActivitySample.record_sessions!("idle-machine", [])
    assert_equal 0, idle.total_sessions
    assert_equal 0, idle.bandwidth_sessions
    assert_equal 0, idle.bandwidth_kbps

    sample = PlexActivitySample.record_sessions!("unknown-bandwidth", [
      { session: { bandwidth: "-1" } }, { session: { bandwidth: "" } }, {}, { session: { bandwidth: "0" } }
    ])
    assert_equal 4, sample.unknown_sessions
    assert_equal 1, sample.bandwidth_sessions
    assert_equal 0, sample.bandwidth_kbps
  end

  test "one sample per machine and minute prevents retries from multiplying observations" do
    now = Time.zone.local(2026, 9, 29, 12, 15, 10)
    first = PlexActivitySample.record_sessions!("same-machine", [], sampled_at: now)

    assert_no_difference "PlexActivitySample.count" do
      duplicate = PlexActivitySample.record_sessions!("same-machine", [ {} ], sampled_at: now + 30.seconds)
      assert_equal first.id, duplicate.id
      assert_equal 0, duplicate.total_sessions
    end
    assert_difference "PlexActivitySample.count", 2 do
      PlexActivitySample.record_sessions!("other-machine", [], sampled_at: now)
      PlexActivitySample.record_sessions!("same-machine", [], sampled_at: now + 1.minute)
    end
    assert_equal now.beginning_of_minute, first.sampled_at
  end

  test "retention deletes only samples before the cutoff across machines" do
    cutoff = 90.days.ago.beginning_of_minute
    PlexActivitySample.record_sessions!("first", [], sampled_at: cutoff - 1.minute)
    PlexActivitySample.record_sessions!("second", [], sampled_at: cutoff - 1.day)
    boundary = PlexActivitySample.record_sessions!("first", [], sampled_at: cutoff)
    recent = PlexActivitySample.record_sessions!("second", [], sampled_at: Time.current)

    assert_equal 2, PlexActivitySample.prune!(older_than: cutoff)
    assert_equal [ boundary.id, recent.id ].sort, PlexActivitySample.pluck(:id).sort
    assert_equal 0, PlexActivitySample.prune!(older_than: cutoff)
  end

  test "invalid retention configuration cannot silently reduce retention to one day" do
    assert_equal 90, PlexActivitySample.retention_days
    PlexActivitySample.record_sessions!("retention", [], sampled_at: 10.days.ago)

    %w[typo 0 -1 3651 1.5].each do |value|
      ENV["PLEX_ACTIVITY_RETENTION_DAYS"] = value
      assert_no_difference "PlexActivitySample.count" do
        assert_raises(Plex::ConfigurationError) { PlexActivitySample.prune! }
      end
    end
    ENV["PLEX_ACTIVITY_RETENTION_DAYS"] = "30"
    assert_equal 30, PlexActivitySample.retention_days
  end

  test "sampling is enabled by default and honors the disable switch" do
    assert PlexActivitySample.enabled?
    ENV["PLEX_ACTIVITY_ENABLED"] = "false"
    assert_not PlexActivitySample.enabled?
    ENV["PLEX_ACTIVITY_ENABLED"] = "0"
    assert_not PlexActivitySample.enabled?
  end
end
