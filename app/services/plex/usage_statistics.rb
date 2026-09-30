module Plex
  class UsageStatistics
    MOVIE_IDENTITY_SQL = <<~SQL.squish.freeze
      COALESCE('id:' || NULLIF(rating_key, ''),
        'title:' || COALESCE(NULLIF(title, ''), NULLIF(full_title, '')),
        'event:' || id::text)
    SQL
    SHOW_IDENTITY_SQL = <<~SQL.squish.freeze
      COALESCE('id:' || NULLIF(metadata->>'grandparent_rating_key', ''),
        'title:' || COALESCE(NULLIF(metadata->>'grandparent_title', ''), NULLIF(split_part(full_title, ' - ', 1), '')),
        'episode:' || NULLIF(rating_key, ''), 'event:' || id::text)
    SQL
    DEFAULT_SECTIONS = %i[summary libraries types activity users movies shows].freeze
    AGGREGATES_SQL = {
      summary: <<~SQL,
        SELECT 'summary' AS section, NULL::text AS identifier, NULL::text AS label,
          COUNT(*) AS plays, COUNT(DISTINCT account_id) AS users,
          MIN(viewed_at) AS oldest, MAX(viewed_at) AS latest FROM plays
      SQL
      libraries: <<~SQL,
        (SELECT 'libraries', library_identifier, NULL, COUNT(*), COUNT(DISTINCT account_id), NULL, MAX(viewed_at)
          FROM plays GROUP BY library_identifier ORDER BY COUNT(*) DESC, library_identifier LIMIT 12)
      SQL
      types: <<~SQL,
        (SELECT 'types', media_type, NULL, COUNT(*), COUNT(DISTINCT account_id), NULL, NULL
          FROM plays GROUP BY media_type ORDER BY COUNT(*) DESC, media_type)
      SQL
      activity: <<~SQL,
        SELECT 'activity', date_trunc(:bucket, viewed_at AT TIME ZONE 'UTC' AT TIME ZONE :zone)::date::text,
          NULL, COUNT(*), NULL, NULL, NULL FROM plays GROUP BY 2
      SQL
      users: <<~SQL,
        (SELECT 'users', account_id, NULL, COUNT(*), NULL, NULL, MAX(viewed_at)
          FROM plays GROUP BY account_id ORDER BY COUNT(*) DESC, account_id LIMIT 12)
      SQL
      movies: <<~SQL,
        (SELECT 'movies', movie_identity, MIN(aggregate_title), COUNT(*), COUNT(DISTINCT account_id), NULL, MAX(viewed_at)
          FROM plays WHERE media_type = 'movie' GROUP BY movie_identity
          ORDER BY COUNT(*) DESC, MIN(aggregate_title), movie_identity LIMIT 10)
      SQL
      shows: <<~SQL,
        (SELECT 'shows', show_identity, MIN(aggregate_title), COUNT(*), COUNT(DISTINCT account_id), NULL, MAX(viewed_at)
          FROM plays WHERE media_type = 'episode' GROUP BY show_identity
          ORDER BY COUNT(*) DESC, MIN(aggregate_title), show_identity LIMIT 10)
      SQL
      recent: <<~SQL
        (SELECT 'recent', id::text, NULL, NULL, NULL, NULL, viewed_at
          FROM plays ORDER BY viewed_at DESC, id DESC LIMIT 50)
      SQL
    }.freeze

    def initialize(scope:, bucket:, sections: DEFAULT_SECTIONS)
      raise ArgumentError, "Unsupported activity bucket" unless %w[day month].include?(bucket.to_s)
      unless sections.is_a?(Array) && sections.any? && sections.all? { |section| AGGREGATES_SQL.key?(section) }
        raise ArgumentError, "Unsupported usage statistics section"
      end

      @scope = scope
      @bucket = bucket.to_s
      @sections = sections.uniq
    end

    def call
      # Each dashboard used to repeat the same expensive completion-deduplication
      # sort for every card. Materialize it once, entirely inside PostgreSQL, and
      # return only bounded rankings and grouped date buckets to the application.
      projection = @scope.reorder(nil).reselect(*projection_columns)
      aggregates = PlexStreamEvent.sanitize_sql_array([
        @sections.map { |section| AGGREGATES_SQL.fetch(section) }.join(" UNION ALL "),
        bucket: @bucket, zone: Time.zone.tzinfo.name
      ])
      sql = <<~SQL
        WITH plays AS MATERIALIZED (#{projection.to_sql})
        SELECT * FROM (#{aggregates}) AS usage_rows(section, identifier, label, plays, users, oldest, latest)
        ORDER BY section,
          CASE WHEN section = 'recent' THEN latest END DESC,
          CASE WHEN section = 'recent' THEN identifier::bigint END DESC,
          plays DESC NULLS LAST, label, identifier
      SQL
      rows = PlexStreamEvent.connection.select_all(sql, "Plex usage statistics").cast_values
      result = { summary: {}, libraries: [], types: [], activity: {}, users: [], movies: [], shows: [], recent: [] }
      rows.each do |section, identifier, label, plays, users, oldest, latest|
        case section
        when "summary"
          result[:summary] = { completed_plays: plays, users: users, oldest: oldest&.in_time_zone, newest: latest&.in_time_zone }
        when "activity"
          result[:activity][Date.iso8601(identifier)] = plays
        else
          result.fetch(section.to_sym) << { identifier: identifier, label: label, plays: plays, users: users, latest: latest&.in_time_zone }
        end
      end
      result
    end

    private

    def projection_columns
      columns = [ :account_id, :viewed_at, :media_type ]
      columns << :id if @sections.include?(:recent)
      columns << Arel.sql("#{PlexStreamEvent::LIBRARY_IDENTIFIER_SQL} AS library_identifier") if @sections.include?(:libraries)
      if @sections.intersect?(%i[movies shows])
        columns << Arel.sql("#{PlexStreamEvent::AGGREGATE_TITLE_SQL} AS aggregate_title")
      end
      columns << Arel.sql("#{MOVIE_IDENTITY_SQL} AS movie_identity") if @sections.include?(:movies)
      columns << Arel.sql("#{SHOW_IDENTITY_SQL} AS show_identity") if @sections.include?(:shows)
      columns
    end
  end
end
