require "test_helper"

class StatusControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_admin_user = ENV["ADMIN_USER"]
    @original_app_revision = ENV["APP_REVISION"]
    @original_git_sha = ENV["GIT_SHA"]
    @original_daily_refresh_at = ENV["PLEX_DAILY_REFRESH_AT"]
    @original_machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"]
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV["PLEX_DAILY_REFRESH_AT"] = "04:15"
    ENV.delete("APP_REVISION")
    ENV.delete("GIT_SHA")
    ENV.delete("ADMIN_USER")
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["ADMIN_USER"] = @original_admin_user
    ENV["APP_REVISION"] = @original_app_revision
    ENV["GIT_SHA"] = @original_git_sha
    ENV["PLEX_DAILY_REFRESH_AT"] = @original_daily_refresh_at
    ENV["PLEX_MACHINE_IDENTIFIER"] = @original_machine_identifier
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "renders status page" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      viewed_at: Time.zone.local(2026, 5, 24, 12, 0, 0),
      full_title: "Feature",
      media_type: "movie"
    )
    PlexActivitySample.create!(
      machine_identifier: "machine-one",
      sampled_at: Time.zone.local(2026, 5, 25, 12, 0, 0),
      total_sessions: 3,
      transcode_sessions: 1
    )
    ENV["PLEX_MACHINE_IDENTIFIER"] = "machine-one"

    get status_path

    assert_response :success
    assert_select "h1", "Status"
    assert_select "p", text: "Database"
    assert_select "p", text: "Next Scheduled"
    assert_select "form[action='#{refresh_shares_path}']", count: 0
    assert_select "input[type=checkbox][name='include_history']", count: 0
    assert_select "h2", "Playback History"
    assert_select "h2", "Activity history"
    assert_select "dd", text: "3"
  end

  test "renders revision from environment" do
    ENV["APP_REVISION"] = "abc1234"

    get status_path

    assert_response :success
    assert_select "p", text: "abc1234"
  end

  test "daily refresh display uses the scheduler timezone and rejects malformed times" do
    original_tz = ENV["TZ"]
    ENV["TZ"] = "America/New_York"
    travel_to Time.utc(2026, 9, 29, 7, 0)
    controller = StatusController.new
    expected = Time.find_zone!("America/New_York").local(2026, 9, 29, 4, 15)
    assert_equal expected, controller.send(:next_daily_refresh_at)
    ENV["PLEX_DAILY_REFRESH_AT"] = "garbage"
    assert_nil controller.send(:next_daily_refresh_at)
  ensure
    ENV["TZ"] = original_tz
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
