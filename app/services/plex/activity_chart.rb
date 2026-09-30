module Plex
  class ActivityChart
    PERIODS = {
      "24h" => { label: "24 hours", duration: 24.hours, bucket: 10.minutes },
      "7d" => { label: "7 days", duration: 7.days, bucket: 1.hour },
      "30d" => { label: "30 days", duration: 30.days, bucket: 6.hours }
    }.freeze
    BUCKET_SQL = {
      "24h" => Arel.sql("FLOOR(EXTRACT(EPOCH FROM sampled_at) / 600)::bigint"),
      "7d" => Arel.sql("FLOOR(EXTRACT(EPOCH FROM sampled_at) / 3600)::bigint"),
      "30d" => Arel.sql("FLOOR(EXTRACT(EPOCH FROM sampled_at) / 21600)::bigint")
    }.freeze

    attr_reader :period, :points, :latest_at, :starts_at, :ends_at, :bucket_seconds

    def initialize(machine_identifier:, period: nil, now: Time.current)
      @period = period.presence_in(PERIODS.keys) || "24h"
      options = PERIODS.fetch(@period)
      @bucket_seconds = options[:bucket].to_i
      @ends_at = now
      @starts_at = now - options[:duration]
      scope = PlexActivitySample.where(machine_identifier: machine_identifier)
      @latest_at = scope.maximum(:sampled_at)
      # Group in PostgreSQL, returning at most 169 rows, independent of retention.
      bucket = BUCKET_SQL.fetch(@period)
      rows = scope.where(sampled_at: @starts_at..now).group(bucket).pluck(bucket,
        Arel.sql("COUNT(*)"), Arel.sql("MAX(total_sessions)"), Arel.sql("MAX(transcode_sessions)"),
        Arel.sql("MAX(direct_play_sessions)"), Arel.sql("MAX(direct_stream_sessions)"),
        Arel.sql("MAX(unknown_sessions)"),
        Arel.sql("MAX(CASE WHEN bandwidth_sessions = total_sessions THEN bandwidth_kbps END)"),
        Arel.sql("COUNT(*) FILTER (WHERE bandwidth_sessions = total_sessions)"))
      grouped = rows.index_by(&:first)
      @points = ((@starts_at.to_i / @bucket_seconds)..(now.to_i / @bucket_seconds)).map do |index|
        row = grouped[index]
        { at: Time.at(index * @bucket_seconds).utc, samples: row&.at(1).to_i,
          total: row&.at(2), transcode: row&.at(3), direct_play: row&.at(4), direct_stream: row&.at(5),
          unknown: row&.at(6), bandwidth: row&.at(7)&.fdiv(1000), bandwidth_samples: row&.at(8).to_i }
      end
    end

    def sample_count
      points.sum { |point| point[:samples] }
    end

    def coverage
      [ 100.0 * sample_count / ((ends_at - starts_at) / 60), 100 ].min.round(1)
    end

    def peak(key)
      points.filter_map { |point| point[key] }.max
    end

    def stale?
      !latest_at || latest_at < ends_at - 3.minutes
    end
  end
end
