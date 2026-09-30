require "test_helper"

class NowPlayingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_admin_user = ENV["ADMIN_USER"]
    @original_plex_token = ENV["PLEX_TOKEN"]
    @original_plex_server_base_url = ENV["PLEX_SERVER_BASE_URL"]
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV["PLEX_TOKEN"] = "token"
    ENV["PLEX_SERVER_BASE_URL"] = "http://plex.example"
    ENV.delete("ADMIN_USER")
    Rails.cache.clear
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["ADMIN_USER"] = @original_admin_user
    ENV["PLEX_TOKEN"] = @original_plex_token
    ENV["PLEX_SERVER_BASE_URL"] = @original_plex_server_base_url
    Rails.cache.clear
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "renders current Plex sessions" do
    client = Class.new do
      def playback_sessions
        [
          {
            title: "The Noise That Blue Makes",
            grandparent_title: "Taskmaster",
            type: "episode",
            library_section_title: "TV Shows",
            duration: "1000",
            view_offset: "500",
            grandparent_thumb: "/library/metadata/1/thumb/123",
            user: { title: "Viewer" },
            player: { title: "Apple TV", platform: "tvOS", address: "192.0.2.10", state: "playing" },
            session: { id: "session-one" }
          }
        ]
      end
    end.new

    original_from_env = Plex::Client.method(:from_env)
    begin
      Plex::Client.define_singleton_method(:from_env) { client }
      get now_playing_path

      assert_response :success
      assert_select "h1", "Now Playing"
      assert_select "h2", "Playing"
      assert_select "p", text: "1 active stream"
      assert_select "h3", "Taskmaster - The Noise That Blue Makes"
      assert_select "p", "Viewer"
      assert_select "dd", text: "Apple TV · tvOS"
      assert_select "dd", text: "192.0.2.10"
      assert_select "p", text: "50% complete"
      assert_select "img[src*='/plex_cover']"
      assert_select "div.self-start[class~='aspect-[2/3]'] > img.absolute.object-cover"
      assert_select "img[src*='%2Flibrary%2Fmetadata%2F1%2Fthumb%2F123']"
      assert_select "div[data-controller='auto-refresh'][data-auto-refresh-interval-value='10000']"
      assert_select "a[aria-label='Tile view'][aria-current='page']"
      assert_select "a[aria-label='Compact list view']"
      assert_select ".flex-1 h3.truncate"
      assert_select "dd.break-all", text: "session-one"
    ensure
      Plex::Client.define_singleton_method(:from_env) { original_from_env.call }
    end
  end

  test "renders sessions partial for background refreshes" do
    client = Class.new do
      def playback_sessions
        [
          {
            title: "Feature",
            type: "movie",
            library_section_title: "Movies",
            duration: "1000",
            view_offset: "250",
            user: { title: "Viewer" },
            player: { title: "Apple TV", platform: "tvOS", state: "playing" },
            session: { id: "session-one" }
          }
        ]
      end
    end.new

    original_from_env = Plex::Client.method(:from_env)
    begin
      Plex::Client.define_singleton_method(:from_env) { client }
      get now_playing_path(partial: 1)

      assert_response :success
      assert_select "h1", false
      assert_select "h3", "Feature"
      assert_select "p", text: "25% complete"
    ensure
      Plex::Client.define_singleton_method(:from_env) { original_from_env.call }
    end
  end

  test "falls back to remote public address for now playing ip" do
    client = Class.new do
      def playback_sessions
        [
          {
            title: "Feature",
            type: "movie",
            library_section_title: "Movies",
            user: { title: "Viewer" },
            player: { title: "Roku", platform: "Roku", remote_public_address: "198.51.100.20", state: "playing" }
          }
        ]
      end
    end.new

    original_from_env = Plex::Client.method(:from_env)
    begin
      Plex::Client.define_singleton_method(:from_env) { client }
      get now_playing_path

      assert_response :success
      assert_select "dd", text: "198.51.100.20"
    ensure
      Plex::Client.define_singleton_method(:from_env) { original_from_env.call }
    end
  end

  test "sorts by newest inferred start and separates paused sessions" do
    client = Class.new do
      def playback_sessions
        [
          {
            title: "Older Playing",
            duration: "1000000",
            view_offset: "600000",
            user: { title: "Viewer" },
            player: { title: "Apple TV", state: "playing" }
          },
          {
            title: "Paused Feature",
            duration: "1000000",
            view_offset: "1000",
            user: { title: "Viewer" },
            player: { title: "Roku", state: "paused" }
          },
          {
            title: "Newest Playing",
            duration: "1000000",
            view_offset: "1000",
            user: { title: "Viewer" },
            player: { title: "Shield", state: "playing" }
          }
        ]
      end
    end.new

    original_from_env = Plex::Client.method(:from_env)
    begin
      Plex::Client.define_singleton_method(:from_env) { client }
      get now_playing_path

      assert_response :success
      body = @response.body
      assert_operator body.index("Newest Playing"), :<, body.index("Older Playing")
      assert_operator body.index("Older Playing"), :<, body.index("Paused Feature")
      assert_no_match(/playings|pauseds/, body)
      assert_select "h2", "Playing"
      assert_select "p", text: "2 active streams"
      assert_select "h2", "Paused"
      assert_select "p", text: "1 paused stream"
    ensure
      Plex::Client.define_singleton_method(:from_env) { original_from_env.call }
    end
  end

  test "renders compact list view" do
    client = Class.new do
      def playback_sessions
        [
          {
            title: "Feature",
            type: "movie",
            duration: "1000",
            view_offset: "250",
            user: { title: "Viewer" },
            player: { title: "Apple TV", platform: "tvOS", state: "playing" }
          }
        ]
      end
    end.new

    original_from_env = Plex::Client.method(:from_env)
    begin
      Plex::Client.define_singleton_method(:from_env) { client }
      get now_playing_path(view: "compact")

      assert_response :success
      assert_select "a[aria-label='Compact list view'][aria-current='page']"
      assert_select "table"
      assert_select "th", "Started"
      assert_select "td p", text: "Feature"
      assert_select "article", count: 0
    ensure
      Plex::Client.define_singleton_method(:from_env) { original_from_env.call }
    end
  end

  test "cached sessions retain their observation time and are isolated by server" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    original = Plex::Client.method(:from_env)
    calls = 0
    client = Object.new
    client.define_singleton_method(:playback_sessions) { calls += 1; [] }
    Plex::Client.define_singleton_method(:from_env) { client }
    observed = Time.zone.local(2026, 9, 29, 12, 0, 58)
    travel_to observed

    get now_playing_path
    assert_response :success
    travel 4.seconds
    get now_playing_path
    assert_response :success
    assert_equal 1, calls
    assert_select "p", text: "Checked #{I18n.l(observed, format: :short)}"

    ENV["PLEX_SERVER_BASE_URL"] = "http://another.example.test"
    get now_playing_path
    assert_response :success
    assert_equal 2, calls
  ensure
    Rails.cache = original_cache
    Plex::Client.define_singleton_method(:from_env, original) if original
    travel_back
  end

  private

  def sign_in
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      info: {
        email: "admin@example.com",
        name: "Admin User"
      }
    )

    post "/auth/google_oauth2/callback", env: {
      "omniauth.auth" => OmniAuth.config.mock_auth[:google_oauth2]
    }

    follow_redirect!
  end
end
