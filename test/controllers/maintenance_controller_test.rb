require "test_helper"

class MaintenanceControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"]
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV["PLEX_MACHINE_IDENTIFIER"] = "machine-one"
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["PLEX_MACHINE_IDENTIFIER"] = @original_machine_identifier
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "renders maintenance page" do
    PlexActivitySample.create!(
      machine_identifier: "machine-one",
      sampled_at: Time.zone.local(2026, 5, 25, 12, 0, 0)
    )

    get_content maintenance_path

    assert_response :success
    assert_select "h1", "Maintenance"
    assert_select "h2", "Plex Data Refresh"
    assert_select "form[action='#{refresh_shares_path}']"
    assert_select "input[type=checkbox][name='include_history']"
    assert_select "h2", "Activity history"
    assert_select "form[action='#{maintenance_sample_now_playing_path}']"
    assert_select "form[action='#{maintenance_prune_now_playing_samples_path}']"
  end

  test "renders refresh panel partial" do
    RefreshRun.create!(
      machine_identifier: "machine-one",
      status: "running",
      admin_email: "admin@example.com",
      include_history: true,
      started_at: Time.current,
      last_message: "History page 4 retrieved",
      history_pages_retrieved: 4,
      history_rows_retrieved: 4000
    )

    get maintenance_refresh_path

    assert_response :success
    assert_select "h2", "Plex Data Refresh"
    assert_select "dd", text: "History page 4 retrieved"
    assert_select "[data-controller='auto-refresh']"
  end

  test "prunes activity history" do
    PlexActivitySample.create!(
      machine_identifier: "machine-one",
      sampled_at: 91.days.ago
    )

    assert_difference -> { PlexActivitySample.count }, -1 do
      post maintenance_prune_now_playing_samples_path
    end
    assert_redirected_to maintenance_path
  end

  test "invalid retention is visible and cannot delete records" do
    original = ENV["PLEX_ACTIVITY_RETENTION_DAYS"]
    ENV["PLEX_ACTIVITY_RETENTION_DAYS"] = "invalid"

    get_content maintenance_path
    assert_response :success
    assert_select "[role=alert]", text: /PLEX_ACTIVITY_RETENTION_DAYS/
    assert_no_difference -> { PlexActivitySample.count } do
      post maintenance_prune_now_playing_samples_path
    end
    assert_redirected_to maintenance_path
  ensure
    ENV["PLEX_ACTIVITY_RETENTION_DAYS"] = original
  end

  test "manual collection stores an idle poll without legacy details" do
    original_url = ENV["PLEX_SERVER_BASE_URL"]
    original_token = ENV["PLEX_TOKEN"]
    ENV["PLEX_SERVER_BASE_URL"] = "http://plex.example.test"
    ENV["PLEX_TOKEN"] = "fixture-token"
    client = Object.new
    client.define_singleton_method(:playback_sessions) { [] }
    original = Plex::Client.method(:from_env)
    Plex::Client.define_singleton_method(:from_env) { client }

    assert_no_difference -> { PlexNowPlayingSample.count } do
      assert_difference -> { PlexActivitySample.count }, 1 do
        post maintenance_sample_now_playing_path
      end
    end
    assert_redirected_to maintenance_path
    assert_equal 0, PlexActivitySample.last.total_sessions
  ensure
    Plex::Client.define_singleton_method(:from_env, original) if original
    ENV["PLEX_SERVER_BASE_URL"] = original_url
    ENV["PLEX_TOKEN"] = original_token
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
