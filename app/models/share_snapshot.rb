class ShareSnapshot < ApplicationRecord
  class BusyError < Plex::ConfigurationError; end

  validates :machine_identifier, :fetched_at, presence: true

  scope :latest_first, -> { order(fetched_at: :desc, created_at: :desc, id: :desc) }

  def self.with_server_lock(machine_identifier)
    connection_pool.with_connection do |connection|
      key = connection.quote("plex:shares:#{machine_identifier}")
      lock = "hashtextextended(#{key}, 0)"
      acquired = connection.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{lock})") }
      raise BusyError, "Another Plex access update is in progress. Please try again shortly." unless acquired

      # A session lock serializes API/cache writes without rolling back audit entries.
      begin
        yield
      ensure
        connection.uncached { connection.select_value("SELECT pg_advisory_unlock(#{lock})") }
      end
    end
  end

  def self.library_version(library_ids)
    Digest::SHA256.hexdigest(library_ids.map(&:to_s).sort.to_json)
  end

  def self.latest_for(machine_identifier)
    where(machine_identifier: machine_identifier).latest_first.first
  end

  def self.checkpoint_streams!(machine_identifier, streams)
    with_server_lock(machine_identifier) { write_stream_checkpoint!(machine_identifier, streams) }
  rescue BusyError
    # Events are already durable; the final refresh will recover their timestamps.
    nil
  end

  def self.write_stream_checkpoint!(machine_identifier, streams)
    snapshot = latest_for(machine_identifier)
    return unless snapshot && streams.present?

    changed = false
    users = snapshot.users.map do |user|
      stream = streams[user["id"].to_s]
      next user unless stream && stream[:viewed_at].present?
      next user if user["last_streamed_at"].to_i >= stream[:viewed_at].to_i

      changed = true
      user.merge(
        "last_streamed_at" => stream[:viewed_at],
        "last_streamed_title" => Plex::StreamFormatter.title(stream),
        "last_streamed_type" => stream[:type]
      )
    end
    return unless changed

    create!(
      machine_identifier: snapshot.machine_identifier,
      server: snapshot.server,
      libraries: snapshot.libraries,
      users: users,
      fetched_at: Time.current
    )
  end
  private_class_method :write_stream_checkpoint!

  def to_report
    Plex::SharingReport::Report.new(
      server: server.symbolize_keys,
      libraries: libraries.map { |library| Plex::SharingReport::Library.new(**library.symbolize_keys) },
      users: users.map { |user| snapshot_user(user) },
      generated_at: fetched_at
    )
  end

  private

  def snapshot_user(user)
    attributes = user.symbolize_keys
    library_rows = attributes.delete(:libraries) || []

    Plex::SharingReport::SharedUser.new(
      id: attributes[:id],
      share_id: attributes[:share_id],
      title: attributes[:title],
      username: attributes[:username],
      email: attributes[:email],
      thumb: attributes[:thumb],
      home: attributes[:home],
      restricted: attributes[:restricted],
      allow_sync: attributes[:allow_sync],
      allow_channels: attributes[:allow_channels],
      last_seen_at: attributes[:last_seen_at],
      last_streamed_at: attributes[:last_streamed_at],
      last_streamed_title: attributes[:last_streamed_title],
      last_streamed_type: attributes[:last_streamed_type],
      invited_at: attributes[:invited_at],
      invite_friend: attributes[:invite_friend],
      invite_server: attributes[:invite_server],
      pending: attributes[:pending],
      all_libraries: attributes[:all_libraries],
      library_count: attributes[:library_count],
      libraries: library_rows.map { |library| Plex::SharingReport::Library.new(**library.symbolize_keys) }
    )
  end
end
