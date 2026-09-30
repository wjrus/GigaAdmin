require "test_helper"

class DeferredPagesTest < ActionDispatch::IntegrationTest
  setup do
    @previous_environment = %w[ADMIN_USERS PLEX_MACHINE_IDENTIFIER].to_h { |key| [ key, ENV[key] ] }
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV["PLEX_MACHINE_IDENTIFIER"] = "machine-one"
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(info: { email: "admin@example.com" })
    post "/auth/google_oauth2/callback", env: { "omniauth.auth" => OmniAuth.config.mock_auth[:google_oauth2] }
  end

  teardown do
    @previous_environment.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "all data pages render navigation without querying their data or calling Plex" do
    original_client = Plex::Client.method(:from_env)
    Plex::Client.define_singleton_method(:from_env) { raise "Page shell must not contact Plex" }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      sql = args.last[:sql]
      queries << sql if sql.match?(/\b(?:plex_stream_events|plex_activity_samples|plex_now_playing_samples|share_snapshots|share_audit_logs|refresh_runs|plex_user_notes)\b/i)
    end
    [ root_path, users_path, user_path("42"), library_path("Movies"), stats_path(period: "90d"),
      now_playing_path, maintenance_path, status_path, share_audit_logs_path, suppressed_users_path ].each do |path|
      queries.clear
      get path
      assert_response :success
      assert_select "nav[aria-label='Page navigation']", count: 1
      assert_select "turbo-frame#page-content[src][target='_top']", count: 1
      assert_select "turbo-frame#page-content[src]" do |frames|
        assert_equal path, frames.first["src"]
      end
      assert_empty queries, "#{path} ran page queries in its initial response"
      assert_includes response.headers["Vary"], "Turbo-Frame"
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Plex::Client.define_singleton_method(:from_env, original_client) if original_client
  end

  test "frame requests render actual data in a matching frame with no recursive source" do
    get stats_path(period: "90d"), headers: { "Turbo-Frame" => "page-content" }
    assert_response :success
    assert_select "turbo-frame#page-content:not([src])[target='_top']", count: 1
    assert_select "h2", text: "Top 10 Shows"
    assert_select "nav[aria-label='Stats period'] a[aria-current=page]", text: "Last 3 months"
    assert_no_match(/<!DOCTYPE|<html[ >]/i, response.body)
  end

  test "explicit synchronous fallback is a complete usable page" do
    get stats_path(sync: "1")
    assert_response :success
    assert_select "html", count: 1
    assert_select "h2", text: "Top 10 Movies"
    assert_select "turbo-frame#page-content[src]", count: 0
  end

  test "expired authorization cannot fetch a frame or a shell" do
    ENV["ADMIN_USERS"] = "other@example.com"
    get stats_path, headers: { "Turbo-Frame" => "page-content" }
    assert_redirected_to sign_in_path
    get stats_path
    assert_redirected_to sign_in_path
  end

  test "legacy live refresh partials bypass the shell" do
    original_client = Plex::Client.method(:from_env)
    client = Object.new
    client.define_singleton_method(:playback_sessions) { [] }
    Plex::Client.define_singleton_method(:from_env) { client }
    get now_playing_path(partial: "1")
    assert_response :success
    assert_select "turbo-frame", count: 0
    assert_select "nav[aria-label='Page navigation']", count: 0
    assert_includes response.body, "Nothing is currently streaming."
  ensure
    Plex::Client.define_singleton_method(:from_env, original_client) if original_client
  end
end
