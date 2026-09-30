module Plex
  class ActivityCollector
    def self.call
      machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"].presence ||
        raise(ConfigurationError, "Missing PLEX_MACHINE_IDENTIFIER")
      raise ConfigurationError, "Missing PLEX_SERVER_BASE_URL" if ENV["PLEX_SERVER_BASE_URL"].blank?

      sessions = Client.from_env.playback_sessions
      # A failed request deliberately leaves a gap; an idle server records zero.
      PlexActivitySample.record_sessions!(machine_identifier, sessions)
    end
  end
end
