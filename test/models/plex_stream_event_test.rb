require "test_helper"

class PlexStreamEventTest < ActiveSupport::TestCase
  test "upserts streams by machine account viewed time and rating key" do
    stream = {
      account_id: "42",
      rating_key: "abc",
      viewed_at: "1779649200",
      type: "movie",
      title: "Feature",
      thumb: "/library/metadata/1/thumb/123",
      library_section_title: "Movies",
      player: { title: "Apple TV", platform: "tvOS", address: "192.0.2.10" },
      duration: "1000",
      view_offset: "800"
    }

    assert_difference -> { PlexStreamEvent.count }, 1 do
      assert_equal 1, PlexStreamEvent.upsert_streams!("machine-one", [ stream ])
      assert_equal 0, PlexStreamEvent.upsert_streams!("machine-one", [ stream.merge(title: "Feature Updated") ])
    end

    event = PlexStreamEvent.find_by!(machine_identifier: "machine-one", account_id: "42")
    assert_equal "Feature Updated", event.title
    assert_equal "Movies", event.library_title
    assert_equal "/library/metadata/1/thumb/123", event.cover_path
    assert_equal "Apple TV", event.player_title
    assert_equal "tvOS", event.player_platform
    assert_equal "Apple TV · tvOS", event.player_label
    assert_equal "192.0.2.10", event.ip_address
    assert_equal "Apple TV", event.metadata.dig("player", "title")
  end

  test "stores flat Plex history player fields" do
    stream = {
      account_id: "42",
      rating_key: "abc",
      viewed_at: "1779649200",
      type: "movie",
      title: "Feature",
      player: "Living Room Roku",
      platform: "Roku",
      ip_address: "198.51.100.4"
    }

    PlexStreamEvent.upsert_streams!("machine-one", [ stream ])

    event = PlexStreamEvent.find_by!(machine_identifier: "machine-one", account_id: "42")
    assert_equal "Living Room Roku", event.player_title
    assert_equal "Roku", event.player_platform
    assert_equal "198.51.100.4", event.ip_address
  end

  test "batch counts only new unique events and preserves creation timestamps" do
    stream = { account_id: "42", rating_key: "a", viewed_at: Time.current.to_i, title: "Original" }
    PlexStreamEvent.upsert_streams!("machine-one", [ stream ])
    original_created_at = PlexStreamEvent.find_by!(rating_key: "a").created_at
    travel 1.hour do
      assert_equal 1, PlexStreamEvent.upsert_streams!("machine-one", [ stream, stream.merge(rating_key: "b"), stream ])
    end
    assert_equal original_created_at, PlexStreamEvent.find_by!(rating_key: "a").created_at
    assert_equal 0, PlexStreamEvent.upsert_streams!("machine-one", [])
  end

  test "deduplicates streams inside one upsert batch" do
    stream = {
      account_id: "42",
      rating_key: "abc",
      viewed_at: "1779649200",
      type: "movie",
      title: "Feature",
      library_section_title: "Movies"
    }

    assert_difference -> { PlexStreamEvent.count }, 1 do
      PlexStreamEvent.upsert_streams!("machine-one", [ stream, stream.merge(title: "Feature Updated") ])
    end

    assert_equal "Feature Updated", PlexStreamEvent.find_by!(machine_identifier: "machine-one", account_id: "42").title
  end

  test "normalizes numeric rating keys before deduplicating existing streams" do
    stream = { account_id: "42", rating_key: "123", viewed_at: Time.current.to_i, title: "Feature" }
    PlexStreamEvent.upsert_streams!("machine-one", [ stream ])

    assert_no_difference -> { PlexStreamEvent.count } do
      assert_equal 0, PlexStreamEvent.upsert_streams!("machine-one", [
        stream.merge(rating_key: 123), stream.merge(title: "Updated feature")
      ])
    end
    assert_equal "Updated feature", PlexStreamEvent.find_by!(rating_key: "123").title
  end

  test "player metadata without a title uses a flat fallback rather than a serialized hash" do
    stream = { account_id: "42", viewed_at: Time.current.to_i, player: { platform: "tvOS" }, device: "Living Room" }
    PlexStreamEvent.upsert_streams!("machine-one", [ stream ])

    assert_equal "Living Room", PlexStreamEvent.find_by!(account_id: "42").player_title
  end

  test "latest per account replaces existing ordering and breaks timestamp ties consistently" do
    attrs = { machine_identifier: "latest-test", account_id: "42", viewed_at: Time.current }
    older = PlexStreamEvent.create!(attrs.merge(rating_key: "old", title: "Old", viewed_at: 1.day.ago))
    PlexStreamEvent.create!(attrs.merge(rating_key: "first", title: "First"))
    newest = PlexStreamEvent.create!(attrs.merge(rating_key: "last", title: "Last"))
    other = PlexStreamEvent.create!(attrs.merge(account_id: "43", title: "Other"))
    PlexStreamEvent.create!(attrs.merge(machine_identifier: "other-machine", title: "Elsewhere", viewed_at: 1.day.from_now))

    latest = PlexStreamEvent.for_machine("latest-test").recent.latest_per_account
    assert_equal [ [ "42", newest.title ], [ "43", other.title ] ], latest.map { |event| [ event.account_id, event.title ] }
    assert_equal [ newest.title ], PlexStreamEvent.latest_for_accounts("latest-test", [ older.account_id ]).map(&:title)
  end

  test "completed play scope counts one completion per user title and day" do
    attrs = {
      machine_identifier: "machine-one",
      account_id: "42",
      rating_key: "rating-one",
      full_title: "Feature",
      media_type: "movie",
      duration: 1000
    }
    PlexStreamEvent.create!(attrs.merge(viewed_at: Time.zone.local(2026, 5, 24, 10, 0, 0), view_offset: 100))
    PlexStreamEvent.create!(attrs.merge(viewed_at: Time.zone.local(2026, 5, 24, 10, 5, 0), view_offset: 500))
    PlexStreamEvent.create!(attrs.merge(viewed_at: Time.zone.local(2026, 5, 24, 10, 10, 0), view_offset: 950))
    PlexStreamEvent.create!(attrs.merge(viewed_at: Time.zone.local(2026, 5, 24, 10, 15, 0), view_offset: 980))

    scope = PlexStreamEvent.where(machine_identifier: "machine-one")
    assert_equal 1, PlexStreamEvent.completed_play_scope(scope).count
    assert_equal 1, PlexStreamEvent.history_summary("machine-one")[:completed_plays]
  end

  test "completed play scope dedupes rows when completion data is unavailable" do
    attrs = {
      machine_identifier: "machine-one",
      account_id: "42",
      rating_key: "rating-one",
      full_title: "Feature",
      media_type: "movie"
    }
    PlexStreamEvent.create!(attrs.merge(viewed_at: Time.zone.local(2026, 5, 24, 10, 0, 0)))
    PlexStreamEvent.create!(attrs.merge(viewed_at: Time.zone.local(2026, 5, 24, 10, 5, 0)))
    PlexStreamEvent.create!(attrs.merge(viewed_at: Time.zone.local(2026, 5, 25, 10, 5, 0)))

    scope = PlexStreamEvent.where(machine_identifier: "machine-one")
    assert_equal 2, PlexStreamEvent.completed_play_scope(scope).count
  end

  test "completion deduplication uses the same local date as activity buckets" do
    Time.use_zone("America/New_York") do
      attrs = { machine_identifier: "local-days", account_id: "42", rating_key: "feature", duration: 1000, view_offset: 950 }
      PlexStreamEvent.create!(attrs.merge(viewed_at: Time.utc(2026, 1, 1, 23)))
      latest = PlexStreamEvent.create!(attrs.merge(viewed_at: Time.utc(2026, 1, 2, 1)))
      next_day = PlexStreamEvent.create!(attrs.merge(viewed_at: Time.utc(2026, 1, 2, 6)))
      scope = PlexStreamEvent.completed_play_scope(PlexStreamEvent.for_machine("local-days").recent)

      assert_equal [ latest.id, next_day.id ].sort, scope.pluck(:id).sort
      assert_equal({ Date.new(2026, 1, 1) => 1, Date.new(2026, 1, 2) => 1 }, PlexStreamEvent.activity_counts(scope.recent, bucket: "day"))
    end
  end

  test "completion deduplication distinguishes titles when identifiers and full titles are blank" do
    attrs = { machine_identifier: "blank-identifiers", account_id: "42", rating_key: "", full_title: "", viewed_at: Time.current }
    first = PlexStreamEvent.create!(attrs.merge(title: "First"))
    second = PlexStreamEvent.create!(attrs.merge(title: "Second", viewed_at: 1.minute.ago))

    assert_equal [ first.id, second.id ].sort, PlexStreamEvent.completed_play_scope(PlexStreamEvent.for_machine("blank-identifiers")).pluck(:id).sort
  end

  test "completion calculations do not overflow for long recordings" do
    attrs = { machine_identifier: "long-recording", account_id: "42", viewed_at: Time.current, duration: 300_000_000 }
    completed = PlexStreamEvent.create!(attrs.merge(rating_key: "completed", view_offset: 270_000_000))
    PlexStreamEvent.create!(attrs.merge(rating_key: "incomplete", view_offset: 269_999_999))
    scope = PlexStreamEvent.for_machine("long-recording")

    assert_equal [ completed.id ], scope.completed.pluck(:id)
    assert_equal [ completed.id ], PlexStreamEvent.completed_play_scope(scope).pluck(:id)
  end

  test "history summary computes metadata counts in one scan plus the completion query" do
    attrs = { machine_identifier: "summary-test", account_id: "42", duration: 1000 }
    oldest = PlexStreamEvent.create!(attrs.merge(rating_key: "one", viewed_at: 2.days.ago, view_offset: 950, player_title: "Player", ip_address: "192.0.2.1"))
    PlexStreamEvent.create!(attrs.merge(rating_key: "two", viewed_at: 1.day.ago, view_offset: 100, player_platform: "tvOS", ip_address: ""))
    newest = PlexStreamEvent.create!(attrs.merge(rating_key: "three", viewed_at: Time.current, view_offset: 100, player_title: "", player_platform: ""))
    PlexStreamEvent.create!(attrs.merge(machine_identifier: "other-machine", viewed_at: Time.current))
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT .*plex_stream_events/i) }
    summary = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      PlexStreamEvent.history_summary("summary-test")
    end

    assert_equal({ total: 3, oldest: oldest.reload.viewed_at, newest: newest.reload.viewed_at, completed_plays: 1, with_player: 2, with_ip: 1 }, summary)
    assert_equal 2, queries.size
    assert_equal({ total: 0, oldest: nil, newest: nil, completed_plays: 0, with_player: 0, with_ip: 0 }, PlexStreamEvent.history_summary("no-history"))
  end

  test "completed video play scope ignores audio and inactive libraries" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      rating_key: "movie-one",
      full_title: "Feature",
      library_title: "Movies",
      media_type: "movie",
      duration: 1000,
      view_offset: 950,
      viewed_at: Time.zone.local(2026, 5, 24, 10, 0, 0)
    )
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      rating_key: "track-one",
      full_title: "Song",
      library_title: "Music",
      media_type: "track",
      duration: 1000,
      view_offset: 950,
      viewed_at: Time.zone.local(2026, 5, 24, 11, 0, 0)
    )
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      rating_key: "old-one",
      full_title: "Old Feature",
      library_title: "Old Movies",
      media_type: "movie",
      duration: 1000,
      view_offset: 950,
      viewed_at: Time.zone.local(2026, 5, 24, 12, 0, 0)
    )

    scope = PlexStreamEvent.where(machine_identifier: "machine-one")
    assert_equal [ "Feature" ], PlexStreamEvent.completed_video_play_scope(scope, library_titles: [ "Movies" ], library_ids: []).map(&:full_title)
  end

  test "completed video play scope matches active libraries by metadata library id" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      rating_key: "movie-one",
      full_title: "Feature",
      media_type: "movie",
      duration: 1000,
      view_offset: 950,
      metadata: { library_section_id: "1" },
      viewed_at: Time.zone.local(2026, 5, 24, 10, 0, 0)
    )

    scope = PlexStreamEvent.where(machine_identifier: "machine-one")
    assert_equal [ "Feature" ], PlexStreamEvent.completed_video_play_scope(scope, library_titles: [], library_ids: [ "1" ]).map(&:full_title)
  end

  test "aggregate title uses series title for episodes" do
    event = PlexStreamEvent.new(
      media_type: "episode",
      full_title: "Show - Season 1 - Episode",
      metadata: { grandparent_title: "Show" }
    )

    assert_equal "Show", event.aggregate_title
  end

  test "stats period is applied inside the deduplication query" do
    since = Time.zone.local(2026, 5, 24)
    scope = PlexStreamEvent.completed_video_play_scope(library_titles: [ "Movies" ], library_ids: [], since: since)
    inner_sql = scope.to_sql.split(" IN (", 2).last
    assert_includes inner_sql, "viewed_at >="
  end

  test "SQL activity buckets respect the application timezone" do
    Time.use_zone("America/New_York") do
      event = PlexStreamEvent.create!(machine_identifier: "synthetic-zone", account_id: "42",
        viewed_at: Time.utc(2026, 1, 2, 1), media_type: "movie")
      counts = PlexStreamEvent.activity_counts(PlexStreamEvent.where(id: event.id), bucket: "day")
      assert_equal({ Date.new(2026, 1, 1) => 1 }, counts)
    end
  end
end
