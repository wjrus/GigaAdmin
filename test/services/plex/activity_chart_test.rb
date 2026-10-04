require "test_helper"

class Plex::ActivityChartTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 9, 29, 12, 25)
  end

  test "keeps idle observations distinct from gaps and incomplete bandwidth" do
    idle = record("chart-machine", @now - 20.minutes)
    partial = record("chart-machine", @now - 10.minutes, total: 2, transcode: 1, direct_play: 1, bandwidth_sessions: 1, bandwidth: 4000)
    complete = record("chart-machine", @now, total: 3, transcode: 2, direct_play: 1, bandwidth_sessions: 3, bandwidth: 12500)
    chart = Plex::ActivityChart.new(machine_identifier: "chart-machine", now: @now)
    idle_point = point_for(chart, idle)
    partial_point = point_for(chart, partial)
    complete_point = point_for(chart, complete)

    assert_equal 0, idle_point[:total]
    assert_equal 0.0, idle_point[:bandwidth]
    assert_equal 1, idle_point[:bandwidth_samples]
    assert_equal 2, partial_point[:total]
    assert_nil partial_point[:bandwidth]
    assert_equal 0, partial_point[:bandwidth_samples]
    assert_equal 12.5, complete_point[:bandwidth]
    assert_equal 2, complete_point[:transcode]
    assert_nil chart.points.first[:total]
    assert_nil chart.points.first[:bandwidth]
    assert_equal 0, chart.points.first[:samples]
    assert_equal 3, chart.sample_count
    assert_equal 3, chart.peak(:total)
    assert_equal 0.2, chart.coverage
    assert_not chart.stale?
  end

  test "peaks aggregate within buckets without summing independent delivery peaks" do
    record("bucket-machine", @now - 1.minute, total: 3, transcode: 3, bandwidth_sessions: 3, bandwidth: 6000)
    record("bucket-machine", @now, total: 4, direct_play: 4, bandwidth_sessions: 4, bandwidth: 5000)
    chart = Plex::ActivityChart.new(machine_identifier: "bucket-machine", now: @now)
    point = chart.points.last

    assert_equal 2, point[:samples]
    assert_equal 4, point[:total]
    assert_equal 3, point[:transcode]
    assert_equal 4, point[:direct_play]
    assert_equal 6.0, point[:bandwidth]
  end

  test "scopes the requested time window and machine before aggregation" do
    record("selected-machine", @now - 24.hours - 1.minute, total: 99)
    record("selected-machine", @now - 24.hours, total: 2)
    record("selected-machine", @now, total: 3)
    record("selected-machine", @now + 1.minute, total: 100)
    record("other-machine", @now, total: 200)
    chart = Plex::ActivityChart.new(machine_identifier: "selected-machine", now: @now)

    assert_equal 2, chart.sample_count
    assert_equal 3, chart.peak(:total)
    assert_equal 2, chart.points.first[:total]
    assert_equal 145, chart.points.size
  end

  test "periods have bounded buckets and invalid periods fall back safely" do
    { "24h" => 145, "7d" => 169, "30d" => 121 }.each do |period, maximum|
      chart = Plex::ActivityChart.new(machine_identifier: "empty-machine", period: period, now: @now)
      assert_operator chart.points.size, :<=, maximum
      assert_equal 0, chart.sample_count
      assert_equal 0.0, chart.coverage
      assert_nil chart.peak(:total)
      assert chart.stale?
    end
    chart = Plex::ActivityChart.new(machine_identifier: "empty-machine", period: "unexpected'period", now: @now)
    assert_equal "24h", chart.period
  end

  test "chart groups in SQL without instantiating individual observations" do
    records = (1..100).map do |offset|
      { machine_identifier: "bounded-query", sampled_at: @now - offset.minutes }
    end
    PlexActivitySample.insert_all!(records)
    instantiated = 0
    subscriber = ->(event) { instantiated += event.payload[:record_count] if event.payload[:class_name] == "PlexActivitySample" }
    chart = nil
    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      chart = Plex::ActivityChart.new(machine_identifier: "bounded-query", now: @now)
    end

    assert_equal 0, instantiated
    assert_equal 100, chart.sample_count
  end

  test "latest observation controls stale status even when outside the selected window" do
    record("stale-machine", @now - 2.days)
    chart = Plex::ActivityChart.new(machine_identifier: "stale-machine", now: @now)
    assert_equal 0, chart.sample_count
    assert_equal @now - 2.days, chart.latest_at
    assert chart.stale?

    record("stale-machine", @now - 3.minutes)
    assert_not Plex::ActivityChart.new(machine_identifier: "stale-machine", now: @now).stale?
  end

  test "display gaps interpolate between neighboring observations without changing stored values or summaries" do
    record("interpolated", @now - 50.minutes, total: 0)
    record("interpolated", @now - 10.minutes, total: 6)
    chart = Plex::ActivityChart.new(machine_identifier: "interpolated", now: @now)
    original = chart.points.deep_dup
    displayed = chart.display_points.last(6)

    assert_equal [ 0, 1.5, 3.0, 4.5, 6, nil ], displayed.map { |point| point[:total] }
    assert_empty displayed.first[:estimated]
    assert_includes displayed.second[:estimated], :total
    assert_equal 0, displayed.second[:samples]
    assert_nil chart.display_points.first[:total]
    assert_nil displayed.last[:total]
    assert_empty displayed.last[:estimated]
    assert_equal original, chart.points
    assert_equal 2, chart.sample_count
    assert_equal 6, chart.peak(:total)
    assert_same chart.display_points, chart.display_points
  end

  test "a single missing bucket averages its neighbors independently for each series" do
    record("partial", @now - 20.minutes, total: 2, transcode: 0, bandwidth_sessions: 2, bandwidth: 1000)
    record("partial", @now - 10.minutes, total: 3, transcode: 1, bandwidth_sessions: 1, bandwidth: 5000)
    record("partial", @now, total: 4, transcode: 2, bandwidth_sessions: 4, bandwidth: 12000)
    chart = Plex::ActivityChart.new(machine_identifier: "partial", now: @now)
    point = chart.display_points[-2]

    assert_equal 3, point[:total]
    assert_equal 6.5, point[:bandwidth]
    assert_equal [ :bandwidth ], point[:estimated]
    assert_equal 0, point[:bandwidth_samples]
    assert_equal 1, point[:samples]
    assert_nil chart.points[-2][:bandwidth]
  end

  test "unknown and single observation series cannot invent estimates" do
    chart = Plex::ActivityChart.new(machine_identifier: "empty", now: @now)
    assert chart.display_points.all? { |point| point[:total].nil? && point[:estimated].empty? }

    record("single", @now - 30.minutes, total: 0)
    chart = Plex::ActivityChart.new(machine_identifier: "single", now: @now)
    assert_equal [ 0 ], chart.display_points.filter_map { |point| point[:total] }
    assert chart.display_points.all? { |point| point[:estimated].empty? }
  end

  test "movie and TV bucket peaks preserve legacy unknowns and observed idle zeroes" do
    record("media", @now - 30.minutes, total: 5)
    PlexActivitySample.record_sessions!("media", [], sampled_at: @now - 20.minutes)
    PlexActivitySample.record_sessions!("media", [ { type: "movie" }, { type: "movie" }, { type: "episode" } ], sampled_at: @now - 1.minute)
    PlexActivitySample.record_sessions!("media", [ { type: "episode" }, { type: "episode" }, { type: "track" } ], sampled_at: @now)
    chart = Plex::ActivityChart.new(machine_identifier: "media", now: @now)

    assert_equal [ nil, 0, nil, 2 ], chart.points.last(4).map { |point| point[:movies] }
    assert_equal [ nil, 0, 1.0, 2 ], chart.display_points.last(4).map { |point| point[:movies] }
    assert_equal 2, chart.peak(:movies)
    assert_equal 2, chart.peak(:tv)
    assert_equal 2, chart.points.last[:samples]
    assert_equal [ :movies, :tv ], chart.display_points[-2][:estimated].intersection([ :movies, :tv ])
    assert_nil chart.display_points[-4][:tv]
  end

  private

  def record(machine, at, total: 0, transcode: 0, direct_play: 0, bandwidth_sessions: 0, bandwidth: 0)
    PlexActivitySample.create!(machine_identifier: machine, sampled_at: at, total_sessions: total,
      transcode_sessions: transcode, direct_play_sessions: direct_play,
      bandwidth_sessions: bandwidth_sessions, bandwidth_kbps: bandwidth)
  end

  def point_for(chart, sample)
    chart.points.find { |point| point[:at].to_i / chart.bucket_seconds == sample.sampled_at.to_i / chart.bucket_seconds }
  end
end
