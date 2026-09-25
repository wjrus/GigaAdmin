require "set"

module Plex
  class SharingReport
    Report = Data.define(:server, :libraries, :users, :generated_at)
    SharedUser = Data.define(
      :id,
      :share_id,
      :title,
      :username,
      :email,
      :thumb,
      :home,
      :restricted,
      :allow_sync,
      :allow_channels,
      :last_seen_at,
      :last_streamed_at,
      :last_streamed_title,
      :last_streamed_type,
      :invited_at,
      :invite_friend,
      :invite_server,
      :pending,
      :all_libraries,
      :library_count,
      :libraries
    ) do
      def label
        username.presence || title.presence || email.presence || id.to_s
      end
    end
    Library = Data.define(:id, :key, :title, :type)

    def initialize(client:, machine_identifier:, progress: nil, include_history: true)
      @client = client
      @machine_identifier = machine_identifier.presence
      @progress = progress
      @include_history = include_history
    end

    def call
      raise ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER in .env" unless machine_identifier

      server_data = client.server(machine_identifier)
      library_lookup = build_library_lookup(server_data[:sections])
      shared_servers = client.shared_servers(machine_identifier)
      users_by_id = client.users.index_by { |user| user[:id].to_s }
      last_streams_by_account_id = history_streams
      pending_invites = pending_invites_for_server(server_data[:server], library_lookup, shared_servers)

      Report.new(
        server: server_data[:server],
        libraries: unique_libraries(library_lookup.values),
        users: (
          shared_servers.map { |shared_server| build_user(shared_server, library_lookup, users_by_id, last_streams_by_account_id) } +
          pending_invites
        ).sort_by { |user| user.label.downcase },
        generated_at: Time.zone.now
      )
    end

    def history_streams
      return {} unless include_history?

      page_size = ENV.fetch("PLEX_HISTORY_PAGE_SIZE", "1000").to_i.clamp(1, 2_000)
      max_pages = history_max_pages
      viewed_after = history_viewed_after
      streams = {}
      page = 0

      loop do
        break if max_pages && page >= max_pages

        history = client.playback_history(size: page_size, offset: page * page_size)
        page_streams = history.reject { |stream| before_history_window?(stream, viewed_after) }
        page_streams.each do |stream|
          next if stream[:account_id].blank?

          streams[stream[:account_id].to_s] ||= stream
        end
        stop_reason = if history.empty?
          "empty page"
        elsif viewed_after && history_older_than_window?(history, viewed_after)
          "reached history window"
        elsif history.size < page_size
          "last page"
        end
        progress&.call(
          phase: "page", page: page + 1, rows: history.size, matches: streams.size,
          remaining: 0, remaining_labels: [], streams: streams,
          page_streams: page_streams, stop_reason: stop_reason
        )
        break if stop_reason

        page += 1
      end
      streams
    end

    private

    attr_reader :client, :machine_identifier, :progress

    def build_library_lookup(sections)
      sections.each_with_object({}) do |section, lookup|
        library = Library.new(
          id: section[:id].presence || section[:key],
          key: section[:key].presence || section[:id],
          title: section[:title],
          type: section[:type]
        )
        lookup[library.id.to_s] = library
        lookup[library.key.to_s] = library
      end
    end

    def build_user(shared_server, library_lookup, users_by_id, last_streams_by_account_id)
      user_id = shared_server[:user_id].presence || shared_server.dig(:user, :id)
      user = users_by_id[user_id.to_s] || shared_server[:user] || {}
      server_share = user_server_share(user, shared_server)
      shared_sections = shared_server[:sections].select { |section| truthy?(section[:shared]) }
      all_libraries_access = truthy?(shared_server[:all_libraries]) || truthy?(server_share[:all_libraries])
      shared_libraries = if shared_sections.any?
        unique_libraries(shared_sections.map do |section|
          lookup_library(section, library_lookup)
        end)
      elsif all_libraries_access
        unique_libraries(library_lookup.values)
      else
        []
      end
      last_stream = last_streams_by_account_id[user_id.to_s]

      SharedUser.new(
        id: user[:id].presence || user_id,
        share_id: shared_server[:id].presence || server_share[:id],
        title: user[:title].presence || user[:friendly_name].presence || user[:username],
        username: user[:username],
        email: user[:email],
        thumb: user[:thumb],
        home: truthy?(user[:home]),
        restricted: truthy?(user[:restricted]),
        allow_sync: truthy?(user[:allow_sync]),
        allow_channels: truthy?(user[:allow_channels]),
        last_seen_at: shared_server[:last_seen_at].presence || server_share[:last_seen_at],
        last_streamed_at: last_stream&.dig(:viewed_at),
        last_streamed_title: stream_title(last_stream),
        last_streamed_type: last_stream&.dig(:type),
        invited_at: nil,
        invite_friend: nil,
        invite_server: nil,
        pending: truthy?(shared_server[:pending]) || truthy?(server_share[:pending]),
        all_libraries: all_libraries_access,
        library_count: shared_libraries.size,
        libraries: shared_libraries.sort_by { |library| library.title.to_s.downcase }
      )
    end

    def pending_invites_for_server(server, library_lookup, shared_servers)
      existing_user_ids = shared_servers.filter_map do |shared_server|
        (shared_server[:user_id].presence || shared_server.dig(:user, :id)).to_s.presence
      end.to_set
      client.requested_invites.filter_map do |invite|
        invite_id = invite[:id].to_s
        next if existing_user_ids.include?(invite_id)

        invite_server = Array(invite[:servers]).find do |candidate|
          invite_server_matches?(candidate, server)
        end
        next unless truthy?(invite[:server]) && invite_server

        build_pending_invite(invite, invite_server, library_lookup)
      end
    end

    def invite_server_matches?(candidate, server)
      machine_ids = [ candidate[:machine_identifier], candidate[:client_identifier] ].compact_blank.map(&:to_s)
      return machine_ids.include?(machine_identifier) if machine_ids.any?

      if candidate[:id].present? && server[:id].present?
        return candidate[:id].to_s == server[:id].to_s
      end

      candidate[:name].present? && server[:name].present? && candidate[:name].to_s == server[:name].to_s
    end

    def build_pending_invite(invite, invite_server, library_lookup)
      library_count = invite_server[:num_libraries].to_i
      all_libraries = unique_libraries(library_lookup.values)
      libraries = library_count == all_libraries.size ? all_libraries : []

      SharedUser.new(
        id: invite[:id],
        share_id: nil,
        title: invite[:friendly_name].presence || invite[:username],
        username: invite[:username],
        email: invite[:email],
        thumb: invite[:thumb],
        home: truthy?(invite[:home]),
        restricted: false,
        allow_sync: false,
        allow_channels: false,
        last_seen_at: nil,
        last_streamed_at: nil,
        last_streamed_title: nil,
        last_streamed_type: nil,
        invited_at: invite[:created_at],
        invite_friend: truthy?(invite[:friend]),
        invite_server: truthy?(invite[:server]),
        pending: true,
        all_libraries: libraries.any? && libraries.size == all_libraries.size,
        library_count: library_count,
        libraries: libraries
      )
    end

    def lookup_library(section, library_lookup)
      library_lookup[section[:id].to_s] ||
        library_lookup[section[:key].to_s] ||
        Library.new(
          id: section[:id].presence || section[:key],
          key: section[:key].presence || section[:id],
          title: section[:title].presence || "Library #{section[:id] || section[:key]}",
          type: section[:type]
        )
    end

    def truthy?(value)
      value == true || value.to_s == "1" || value.to_s.casecmp("true").zero?
    end

    def unique_libraries(libraries)
      libraries.uniq { |library| library.id.to_s }.sort_by { |library| library.title.to_s.downcase }
    end

    def stream_title(stream)
      return unless stream

      [ stream[:grandparent_title], stream[:parent_title], stream[:title] ].compact_blank.join(" - ")
    end


    def history_max_pages
      value = ENV.fetch("PLEX_HISTORY_MAX_PAGES", "all")
      return nil if value.to_s.casecmp("all").zero?

      value.to_i.clamp(1, 10_000)
    end

    def history_viewed_after
      days = ENV["PLEX_HISTORY_DAYS"].presence
      return unless days
      return if days.casecmp("all").zero?

      days.to_i.days.ago
    end

    def before_history_window?(stream, viewed_after)
      viewed_after && stream[:viewed_at].to_i < viewed_after.to_i
    end

    def history_older_than_window?(history, viewed_after)
      oldest_viewed_at = history.filter_map { |stream| stream[:viewed_at].presence&.to_i }.min
      oldest_viewed_at && oldest_viewed_at < viewed_after.to_i
    end


    def user_server_share(user, shared_server)
      Array(user[:servers]).find do |server|
        server[:machine_identifier] == machine_identifier || server[:id].to_s == shared_server[:id].to_s
      end || {}
    end

    def include_history?
      @include_history
    end
  end
end
