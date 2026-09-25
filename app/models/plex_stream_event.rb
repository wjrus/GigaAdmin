class PlexStreamEvent < ApplicationRecord
  COMPLETED_SQL = "duration > 0 AND view_offset::bigint * 10 >= duration::bigint * 9".freeze
  PLAY_IDENTITY_SQL = "machine_identifier, account_id, COALESCE(NULLIF(rating_key, ''), NULLIF(full_title, ''), title), (viewed_at AT TIME ZONE 'UTC' AT TIME ZONE :zone)::date".freeze
  LIBRARY_IDENTIFIER_SQL = "COALESCE(NULLIF(library_title, ''), NULLIF(metadata->>'library_section_id', ''), 'unknown')".freeze
  AGGREGATE_TITLE_SQL = <<~SQL.squish.freeze
    CASE WHEN media_type = 'episode' THEN
      COALESCE(NULLIF(metadata->>'grandparent_title', ''), NULLIF(split_part(full_title, ' - ', 1), ''), NULLIF(title, ''), 'Unknown series')
    ELSE COALESCE(NULLIF(title, ''), NULLIF(full_title, ''), 'Unknown title') END
  SQL

  validates :machine_identifier, :account_id, :viewed_at, presence: true

  scope :recent, -> { order(viewed_at: :desc, id: :desc) }
  scope :for_machine, ->(machine_identifier) { where(machine_identifier: machine_identifier) }
  scope :completed, -> { where(COMPLETED_SQL) }
  scope :without_completion_data, -> { where("duration IS NULL OR duration <= 0 OR view_offset IS NULL") }
  scope :video, -> { where(media_type: %w[movie episode]) }
  scope :latest_per_account, lambda {
    select("DISTINCT ON (account_id) account_id, viewed_at, title, full_title, media_type")
      .reorder(:account_id, viewed_at: :desc, id: :desc)
  }
  scope :in_active_libraries, lambda { |library_titles:, library_ids:|
    if library_titles.blank? && library_ids.blank?
      none
    else
      where("library_title IN (:titles) OR metadata->>'library_section_id' IN (:ids)", titles: library_titles, ids: library_ids.map(&:to_s))
    end
  }

  def self.completed_play_scope(scope = all)
    identity = sanitize_sql_array([ PLAY_IDENTITY_SQL, zone: Time.zone.tzinfo.name ])
    deduped_ids = scope
      .where("(#{COMPLETED_SQL}) OR duration IS NULL OR duration <= 0 OR view_offset IS NULL")
      .reselect("DISTINCT ON (#{identity}) plex_stream_events.id")
      .reorder(Arel.sql("#{identity}, viewed_at DESC, id DESC"))

    where(id: deduped_ids)
  end

  def self.completed_video_play_scope(scope = all, library_titles:, library_ids:, since: nil)
    scope = scope.where("viewed_at >= ?", since) if since
    completed_play_scope(scope.video.in_active_libraries(library_titles: library_titles, library_ids: library_ids))
  end

  def self.activity_counts(scope, bucket:)
    raise ArgumentError, "Unsupported activity bucket" unless %w[day month].include?(bucket)

    expression = Arel.sql(sanitize_sql_array([
      "date_trunc(:bucket, viewed_at AT TIME ZONE 'UTC' AT TIME ZONE :zone)::date", bucket: bucket, zone: Time.zone.tzinfo.name
    ]))
    scope.reorder(nil).group(expression).count
  end

  def library_identifier
    library_title.presence || metadata_value(:library_section_id).presence || "unknown"
  end

  def self.for_user(machine_identifier, account_id, limit: 25)
    where(machine_identifier: machine_identifier, account_id: account_id.to_s)
      .recent
      .limit(limit)
  end

  def self.latest_for_accounts(machine_identifier, account_ids)
    for_machine(machine_identifier).where(account_id: account_ids).latest_per_account
  end

  def self.upsert_streams!(machine_identifier, streams)
    rows = Array(streams).filter_map do |stream|
      account_id = stream[:account_id].to_s.presence
      viewed_at = stream[:viewed_at].presence
      next unless account_id && viewed_at

      {
        machine_identifier: machine_identifier,
        account_id: account_id,
        rating_key: stream_identifier(stream),
        media_type: stream[:type].presence,
        title: stream[:title].presence,
        full_title: stream_title(stream),
        cover_path: stream_cover_path(stream),
        library_title: stream[:library_section_title].presence,
        player_title: stream_player_title(stream),
        player_platform: stream_player_platform(stream),
        ip_address: stream_ip_address(stream),
        duration: stream[:duration].presence&.to_i,
        view_offset: stream[:view_offset].presence&.to_i,
        metadata: stream,
        viewed_at: Time.zone.at(viewed_at.to_i),
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    return 0 if rows.empty?

    rows = rows.reverse.uniq do |row|
      [
        row[:machine_identifier],
        row[:account_id],
        row[:viewed_at],
        row[:rating_key]
      ]
    end.reverse

    transaction do
      # Count only this batch's inserts, without scanning the complete history.
      inserted = insert_all(rows, unique_by: :index_stream_events_on_machine_account_viewed_rating,
        returning: %w[account_id rating_key viewed_at])
      inserted_keys = inserted.rows.to_set
      existing = rows.reject { |row| inserted_keys.include?([ row[:account_id], row[:rating_key], row[:viewed_at] ]) }
      if existing.any?
        upsert_all(existing, unique_by: :index_stream_events_on_machine_account_viewed_rating,
          update_only: existing.first.keys.map(&:to_s) - [ "created_at" ], record_timestamps: false)
      end
      inserted.rows.size
    end
  end

  def label
    full_title.presence || title.presence || "Unknown title"
  end

  def aggregate_title
    return series_title if media_type == "episode"

    title.presence || full_title.presence || "Unknown title"
  end

  def series_title
    metadata_value(:grandparent_title).presence ||
      full_title.to_s.split(" - ").first.presence ||
      title.presence ||
      "Unknown series"
  end

  def player_label
    [ player_title, player_platform ].compact_blank.join(" · ").presence || "Unknown"
  end

  def self.history_summary(machine_identifier)
    scope = for_machine(machine_identifier)
    total, oldest, newest, with_player, with_ip = scope.pick(
      Arel.sql("COUNT(*)"), Arel.sql("MIN(viewed_at)"), Arel.sql("MAX(viewed_at)"),
      Arel.sql("COUNT(*) FILTER (WHERE NULLIF(player_title, '') IS NOT NULL OR NULLIF(player_platform, '') IS NOT NULL)"),
      Arel.sql("COUNT(*) FILTER (WHERE NULLIF(ip_address, '') IS NOT NULL)")
    )
    {
      total: total,
      oldest: oldest,
      newest: newest,
      completed_plays: completed_play_scope(scope).count,
      with_player: with_player,
      with_ip: with_ip
    }
  end

  def self.stream_title(stream)
    [ stream[:grandparent_title], stream[:parent_title], stream[:title] ].compact_blank.join(" - ")
  end

  def self.stream_identifier(stream)
    (stream[:rating_key].presence ||
      stream[:key].presence ||
      stream[:guid].presence ||
      stream_title(stream).presence ||
      "unknown").to_s
  end

  def self.stream_cover_path(stream)
    stream[:grandparent_thumb].presence ||
      stream[:thumb].presence ||
      stream[:parent_thumb].presence ||
      stream[:art].presence
  end

  def self.stream_player_title(stream)
    player = stream[:player].is_a?(Hash) ? stream[:player] : {}
    player[:title].presence ||
      stream[:player_title].presence ||
      (stream[:player].presence unless stream[:player].is_a?(Hash)) ||
      stream[:device].presence
  end

  def self.stream_player_platform(stream)
    player = stream[:player].is_a?(Hash) ? stream[:player] : {}
    player[:platform].presence ||
      stream[:player_platform].presence ||
      stream[:platform].presence
  end

  def self.stream_ip_address(stream)
    player = stream[:player].is_a?(Hash) ? stream[:player] : {}
    player[:address].presence ||
      stream[:ip_address].presence ||
      stream[:ip].presence ||
      stream[:address].presence
  end

  def metadata_value(key)
    metadata[key.to_s].presence || metadata[key.to_sym].presence
  end
end
