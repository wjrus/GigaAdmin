require "test_helper"

class FrontendRenderingTest < ActionDispatch::IntegrationTest
  setup do
    @previous_environment = %w[ADMIN_USERS PLEX_MACHINE_IDENTIFIER].to_h { |key| [ key, ENV[key] ] }
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV["PLEX_MACHINE_IDENTIFIER"] = "machine-one"
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    @previous_environment.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "maintenance replaces one active polling panel and drops polling when complete" do
    run = RefreshRun.create!(machine_identifier: "machine-one", status: "running", started_at: Time.current)

    get maintenance_refresh_path
    assert_response :success
    assert_select "[data-controller='auto-refresh'][data-auto-refresh-replace-value='true']", count: 1

    run.update!(status: "completed", finished_at: Time.current)
    get maintenance_refresh_path
    assert_response :success
    assert_select "[data-controller='auto-refresh']", count: 0
    assert_select "button[type=submit]:not([disabled])", text: "Refresh from Plex"
  end

  test "authentication alerts remain available until explicitly dismissed" do
    post "/auth/google_oauth2/callback", env: { "omniauth.auth" => OmniAuth::AuthHash.new(info: { email: "not-allowed@example.test" }) }
    follow_redirect!

    assert_select "[role=alert][data-flash-duration-value='0']" do
      assert_select "button[aria-label='Dismiss message']"
      assert_select ".flash-progress", count: 0
    end
  end

  test "user rows expose native links without replacing table semantics" do
    [ root_path, users_path ].each do |path|
      get_content path
      assert_response :success
      assert_select "tr[data-controller='row-link']" do
        assert_select "a[href='#{user_path('42')}'][data-turbo-prefetch=false]", minimum: 1
      end
      assert_select "tr[role=link]", count: 0
      assert_select "tr[tabindex]", count: 0
    end
  end

  test "destructive dialog has an accessible title and description and handles Escape" do
    get_content user_path("42")

    assert_response :success
    assert_select "dialog[aria-labelledby='confirmation-title'][aria-describedby='confirmation-body'][data-action='cancel->confirmation#cancel']" do
      assert_select "#confirmation-title", count: 1
      assert_select "#confirmation-body", count: 1
    end
  end

  test "legacy session details only appear when stored records exist" do
    get_content user_path("42")
    assert_response :success
    assert_select "h2", text: "Legacy session samples", count: 0

    PlexNowPlayingSample.create!(machine_identifier: "machine-one", account_id: "42", sampled_at: Time.current,
      user_label: "viewer", player_title: "Legacy player", full_title: "Legacy movie")
    get_content user_path("42")

    assert_response :success
    assert_select "h2", text: "Legacy session samples", count: 1
    assert_select "td", text: "Legacy player"
  end

  private

  def sign_in
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(provider: "google_oauth2", info: { email: "admin@example.com" })
    post "/auth/google_oauth2/callback", env: { "omniauth.auth" => OmniAuth.config.mock_auth[:google_oauth2] }
  end
end
