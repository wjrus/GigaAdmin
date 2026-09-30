class PlexActivitySample < ApplicationRecord
  validates :machine_identifier, :sampled_at, presence: true

  scope :recent, -> { order(sampled_at: :desc) }

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("PLEX_ACTIVITY_ENABLED", "true"))
  end

  def self.retention_days
    days = Integer(ENV.fetch("PLEX_ACTIVITY_RETENTION_DAYS", "90"), exception: false)
    unless days&.between?(1, 3650)
      raise Plex::ConfigurationError, "PLEX_ACTIVITY_RETENTION_DAYS must be an integer between 1 and 3650"
    end
    days
  end

  def self.prune!(older_than: retention_days.days.ago)
    where("sampled_at < ?", older_than).in_batches.sum(&:delete_all)
  end

  def self.record_sessions!(machine_identifier, sessions, sampled_at: Time.current)
    counts = {
      total_sessions: sessions.size, playing_sessions: 0, paused_sessions: 0,
      transcode_sessions: 0, direct_play_sessions: 0, direct_stream_sessions: 0,
      unknown_sessions: 0, bandwidth_sessions: 0, bandwidth_kbps: 0
    }
    sessions.each do |stream|
      counts[:playing_sessions] += 1 if Plex::StreamFormatter.playing?(stream)
      counts[:paused_sessions] += 1 if Plex::StreamFormatter.paused?(stream)
      counts["#{delivery_method(stream)}_sessions".to_sym] += 1
      bandwidth = Integer(stream.dig(:session, :bandwidth), exception: false)
      if bandwidth && bandwidth >= 0
        counts[:bandwidth_sessions] += 1
        counts[:bandwidth_kbps] += bandwidth
      end
    end

    # Polling retries and manual collection in the same minute must not multiply rows.
    insert_all([ counts.merge(machine_identifier: machine_identifier, sampled_at: sampled_at.beginning_of_minute) ],
      unique_by: [ :machine_identifier, :sampled_at ])
    find_by!(machine_identifier: machine_identifier, sampled_at: sampled_at.beginning_of_minute)
  end

  def self.delivery_method(stream)
    transcode = stream[:transcode_session] || {}
    media = stream[:media].is_a?(Array) ? stream[:media] : [ stream[:media] ].compact
    selected = media.select { |item| item[:selected].to_s.in?(%w[1 true]) }
    media = selected if selected.any?
    decisions = [ transcode[:video_decision], transcode[:audio_decision] ]
    media.each do |item|
      decisions.concat([ item[:video_decision], item[:audio_decision], item[:decision] ])
      parts = item[:part].is_a?(Array) ? item[:part] : [ item[:part] ].compact
      decisions.concat(parts.map { |part| part[:decision] })
    end
    decisions = decisions.compact.map { |decision| decision.to_s.downcase }
    return :transcode if decisions.include?("transcode")
    return :direct_stream if decisions.intersect?(%w[copy directstream direct_stream])
    return :direct_play if decisions.intersect?(%w[directplay direct_play])

    :unknown
  end
  private_class_method :delivery_method
end
