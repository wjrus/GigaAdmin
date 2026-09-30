require "test_helper"

class Plex::UsageStatisticsTest < ActiveSupport::TestCase
  test "all dashboard aggregates share one deduplicated filtered query" do
    now = Time.zone.local(2026, 9, 29, 12)
    create_event(viewed_at: now, rating_key: "movie", title: "Feature")
    create_event(viewed_at: now - 1.minute, rating_key: "movie", title: "Feature")
    create_event(viewed_at: now, rating_key: "episode-one", media_type: "episode", library_title: "TV",
      metadata: { grandparent_rating_key: "show", grandparent_title: "Series" })
    create_event(viewed_at: now, rating_key: "episode-two", account_id: "43", media_type: "episode", library_title: "TV",
      metadata: { grandparent_rating_key: "show", grandparent_title: "Series" })
    create_event(viewed_at: now, rating_key: "legacy", title: "Legacy", account_id: "43", duration: nil, view_offset: nil)
    create_event(viewed_at: now, rating_key: "incomplete", view_offset: 100)
    create_event(viewed_at: now, rating_key: "audio", media_type: "track")
    create_event(viewed_at: now, rating_key: "inactive", library_title: "Inactive")
    create_event(viewed_at: now, rating_key: "other", machine_identifier: "other-machine")
    create_event(viewed_at: now + 1.second, rating_key: "future")
    create_event(viewed_at: now - 8.days, rating_key: "earlier")
    base = PlexStreamEvent.for_machine("usage-machine").where("viewed_at <= ?", now)
    scope = PlexStreamEvent.completed_video_play_scope(base, library_titles: %w[Movies TV], library_ids: [], since: now - 7.days)
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:name] == "Plex usage statistics" }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Plex::UsageStatistics.new(scope: scope, bucket: "day").call
    end

    assert_equal 1, queries.size
    assert_equal 4, result[:summary][:completed_plays]
    assert_equal 2, result[:summary][:users]
    assert_equal now, result[:summary][:oldest]
    assert_equal now, result[:summary][:newest]
    assert_equal({ "Movies" => 2, "TV" => 2 }, result[:libraries].to_h { |row| [ row[:identifier], row[:plays] ] })
    assert_equal({ "episode" => 2, "movie" => 2 }, result[:types].to_h { |row| [ row[:identifier], row[:plays] ] })
    assert_equal({ now.to_date => 4 }, result[:activity])
    assert_equal [ [ "Series", 2, 2 ] ], result[:shows].map { |row| row.values_at(:label, :plays, :users) }
    assert_equal %w[Feature Legacy], result[:movies].map { |row| row[:label] }
    assert_equal now, result[:movies].first[:latest]
    assert_equal [ [ "42", 2 ], [ "43", 2 ] ], result[:users].map { |row| row.values_at(:identifier, :plays) }
  end

  test "empty scope returns an empty dashboard with no oldest date" do
    result = Plex::UsageStatistics.new(scope: PlexStreamEvent.none, bucket: "month").call

    assert_equal({ completed_plays: 0, users: 0, oldest: nil, newest: nil }, result[:summary])
    assert_empty result[:activity]
    %i[libraries types users movies shows].each { |key| assert_empty result[key] }
  end

  test "buckets and deduplication use the same application timezone" do
    Time.use_zone("America/New_York") do
      create_event(rating_key: "feature", viewed_at: Time.utc(2026, 1, 1, 23))
      create_event(rating_key: "feature", viewed_at: Time.utc(2026, 1, 2, 1))
      create_event(rating_key: "feature", viewed_at: Time.utc(2026, 1, 2, 6))
      scope = PlexStreamEvent.completed_play_scope(PlexStreamEvent.for_machine("usage-machine"))

      result = Plex::UsageStatistics.new(scope: scope.recent, bucket: "day").call
      assert_equal({ Date.new(2026, 1, 1) => 1, Date.new(2026, 1, 2) => 1 }, result[:activity])
      assert_equal "EST", result[:summary][:oldest].zone
    end
  end

  test "monthly buckets use the local month across UTC year boundaries" do
    Time.use_zone("America/New_York") do
      create_event(rating_key: "feature", viewed_at: Time.utc(2026, 1, 1, 1))
      create_event(rating_key: "feature", viewed_at: Time.utc(2026, 1, 1, 6))
      scope = PlexStreamEvent.completed_play_scope(PlexStreamEvent.for_machine("usage-machine"))

      result = Plex::UsageStatistics.new(scope: scope, bucket: "month").call
      assert_equal({ Date.new(2025, 12, 1) => 1, Date.new(2026, 1, 1) => 1 }, result[:activity])
    end
  end

  test "untrusted bucket values are rejected before SQL execution" do
    assert_raises(ArgumentError) do
      Plex::UsageStatistics.new(scope: PlexStreamEvent.none, bucket: "day'); SELECT 1")
    end
  end

  test "selected library sections retain twelve users and fifty recent ids without computing other charts" do
    now = Time.current.change(usec: 0)
    60.times do |index|
      create_event(account_id: "viewer-#{index % 15}", viewed_at: now - index.minutes,
        rating_key: "feature-#{index}", title: "Feature #{index}")
    end
    scope = PlexStreamEvent.completed_play_scope(PlexStreamEvent.for_machine("usage-machine"))
    result = Plex::UsageStatistics.new(scope: scope, bucket: "month", sections: %i[summary types users recent]).call

    assert_equal 60, result[:summary][:completed_plays]
    assert_equal 15, result[:summary][:users]
    assert_equal 12, result[:users].size
    assert_equal 50, result[:recent].size
    assert_equal now, result[:recent].first[:latest]
    assert_empty result[:activity]
    assert_empty result[:movies]
    assert_empty result[:shows]
    assert_raises(ArgumentError) do
      Plex::UsageStatistics.new(scope: scope, bucket: "month", sections: [ "summary; DELETE" ])
    end
  end

  test "allowed sections work independently and in a different order" do
    now = Time.current.change(usec: 0)
    older = create_event(viewed_at: now, rating_key: "one", title: "First")
    newer = create_event(viewed_at: now, rating_key: "two", title: "Second")
    scope = PlexStreamEvent.for_machine("usage-machine")

    recent = Plex::UsageStatistics.new(scope: scope, bucket: "month", sections: [ :recent ]).call
    assert_equal [ newer.id.to_s, older.id.to_s ], recent[:recent].map { |stat| stat[:identifier] }
    reordered = Plex::UsageStatistics.new(scope: scope, bucket: "month", sections: %i[types summary]).call
    assert_equal 2, reordered[:summary][:completed_plays]
    assert_equal [ "movie" ], reordered[:types].map { |stat| stat[:identifier] }
  end

  private

  def create_event(**attributes)
    PlexStreamEvent.create!({ machine_identifier: "usage-machine", account_id: "42", media_type: "movie",
      library_title: "Movies", duration: 1000, view_offset: 950 }.merge(attributes))
  end
end
