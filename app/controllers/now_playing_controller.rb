class NowPlayingController < ApplicationController
  defer_page :index, title: "Now Playing"

  VIEW_MODES = %w[tiles compact].freeze

  def index
    load_sessions
    render partial: "sessions", layout: false if params[:partial].present?
  end

  private

  def load_sessions
    @view_mode = params[:view].presence_in(VIEW_MODES) || "tiles"
    source = [ ENV["PLEX_MACHINE_IDENTIFIER"], ENV["PLEX_SERVER_BASE_URL"], ENV["PLEX_TOKEN"] ].join("\0")
    result = Rails.cache.fetch([ "plex:now_playing:v2", Digest::SHA256.hexdigest(source) ], expires_in: 8.seconds) do
      { sessions: Plex::Client.from_env.playback_sessions, fetched_at: Time.current }
    end
    @sessions = sort_sessions(result[:sessions])
    @playing_sessions = []
    @paused_sessions = []
    @other_sessions = []
    @sessions.each do |stream|
      if Plex::StreamFormatter.playing?(stream)
        @playing_sessions << stream
      elsif Plex::StreamFormatter.paused?(stream)
        @paused_sessions << stream
      else
        @other_sessions << stream
      end
    end
    @fetched_at = result[:fetched_at]
  rescue Plex::ConfigurationError, Plex::Client::Error => error
    @view_mode ||= "tiles"
    @plex_error = error.message
    @sessions = []
    @playing_sessions = []
    @paused_sessions = []
    @other_sessions = []
  end

  def sort_sessions(sessions)
    now = Time.current
    Array(sessions).sort_by do |stream|
      [
        -state_rank(stream),
        -Plex::StreamFormatter.started_at(stream, now: now).to_i,
        Plex::StreamFormatter.user_label(stream).downcase
      ]
    end
  end

  def state_rank(stream)
    return 2 if Plex::StreamFormatter.playing?(stream)
    return 1 if Plex::StreamFormatter.paused?(stream)

    0
  end
end
