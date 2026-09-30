require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_admin_user = ENV["ADMIN_USER"]
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV.delete("ADMIN_USER")
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", info: { email: "admin@example.com", name: "Synthetic Admin" }
    )
    post "/auth/google_oauth2/callback", env: { "omniauth.auth" => OmniAuth.config.mock_auth[:google_oauth2] }
  end

  teardown do
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["ADMIN_USER"] = @original_admin_user
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "removing an admin invalidates their existing session" do
    ENV["ADMIN_USERS"] = "replacement@example.com"
    get users_path
    assert_redirected_to sign_in_path

    ENV["ADMIN_USERS"] = "admin@example.com"
    get users_path
    assert_redirected_to sign_in_path
  end

  test "revoked sessions cannot write notes" do
    ENV["ADMIN_USERS"] = "replacement@example.com"
    assert_no_difference "PlexUserNote.count" do
      patch user_note_path("revoked-test"), params: { plex_user_note: { notes: "Not permitted" } }
    end
    assert_redirected_to sign_in_path
  end

  test "the obsolete singular ADMIN_USER setting cannot grant Google access" do
    ENV["ADMIN_USERS"] = ""
    ENV["ADMIN_USER"] = "admin@example.com"

    post "/auth/google_oauth2/callback", env: { "omniauth.auth" => OmniAuth.config.mock_auth[:google_oauth2] }

    assert_redirected_to sign_in_path
    get users_path
    assert_redirected_to sign_in_path
  end
end
