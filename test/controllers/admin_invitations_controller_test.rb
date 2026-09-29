require "test_helper"

class AdminInvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_auth_mode = ENV["GIGAADMIN_AUTH_MODE"]
    @previous_admin_users = ENV["ADMIN_USERS"]
    ENV["GIGAADMIN_AUTH_MODE"] = "local"
    ENV.delete("ADMIN_USERS")
    @admin = AdminUser.create!(email: "inviter@example.test", password: "correct-horse-battery-staple", super_admin: true)
  end

  teardown do
    ENV["GIGAADMIN_AUTH_MODE"] = @previous_auth_mode
    ENV["ADMIN_USERS"] = @previous_admin_users
  end

  test "creating and revoking invitations requires a local administrator" do
    invitation, = issue_invitation

    assert_no_difference "AdminInvitation.count" do
      post admin_invitations_path, params: invitation_params
    end
    assert_redirected_to sign_in_path

    delete admin_invitation_path(invitation)
    assert_redirected_to sign_in_path
    assert_nil invitation.reload.revoked_at
  end

  test "creating an invitation requires the current administrator password" do
    sign_in

    assert_no_difference "AdminInvitation.count" do
      post admin_invitations_path, params: invitation_params.merge(current_password: "incorrect")
    end
    assert_redirected_to admin_users_path
  end

  test "ordinary administrators cannot create or revoke invitations" do
    invitation, = issue_invitation
    ordinary_admin = AdminUser.create!(email: "ordinary@example.test", password: "correct-horse-battery-staple")
    post local_sign_in_path, params: { session: { email: ordinary_admin.email, password: "correct-horse-battery-staple" } }
    assert_redirected_to root_path

    assert_no_difference "AdminInvitation.count" do
      post admin_invitations_path, params: invitation_params
    end
    assert_response :forbidden

    delete admin_invitation_path(invitation)
    assert_response :forbidden
    assert_nil invitation.reload.revoked_at
  end

  test "password reconfirmation rejects input beyond bcrypt's byte limit" do
    sign_in

    assert_no_difference "AdminInvitation.count" do
      post admin_invitations_path, params: invitation_params.merge(current_password: "p" * 73)
    end
    assert_redirected_to admin_users_path
  end

  test "creating an invitation displays a private single-use link and access warning" do
    sign_in

    assert_difference "AdminInvitation.count", 1 do
      post admin_invitations_path, params: invitation_params
    end

    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_select 'meta[name="turbo-cache-control"][content="no-cache"]', 1
    assert_select "strong", text: "Plex sharing administration:"
    assert_includes response.body, "cannot invite or remove GigaAdmin administrators"
    assert_select "input#invitation-link[readonly]", 1
    link = css_select("input#invitation-link").first["value"]
    token = URI.decode_www_form(URI.parse(link).query).to_h.fetch("token")
    assert_equal "friend@example.test", AdminInvitation.find_available_by_token(token).email
    assert_not_includes request.session.to_hash.values, token
    assert_not_includes request.session.to_hash.values, link
  end

  test "acceptance uses the invited email and signs into the new local account" do
    invitation, token = issue_invitation

    get accept_admin_invitation_path(token: token)
    assert_response :success
    assert_select 'meta[name="turbo-cache-control"][content="no-cache"]', 1
    assert_select "strong", text: "Plex sharing administration:"
    assert_includes response.body, "cannot invite or remove GigaAdmin administrators"
    assert_select "input[name='admin_user[email]']", 0
    assert_equal "no-referrer", response.headers["Referrer-Policy"]

    assert_difference "AdminUser.count", 1 do
      post accept_admin_invitation_path(token: token), params: {
        admin_user: { email: "forged@example.test", password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple" }
      }
    end

    assert_redirected_to root_path
    invited_admin = AdminUser.find_by!(email: invitation.email)
    assert_equal invited_admin.id, request.session[:local_admin_id]
    assert_equal invited_admin.session_version, request.session[:local_admin_version]
    assert_not invited_admin.super_admin?
    assert_not AdminUser.exists?(email: "forged@example.test")
    assert invitation.reload.accepted_at

    get accept_admin_invitation_path(token: token)
    assert_response :gone
  end

  test "invitations disclose additional authority explicitly granted by ADMIN_USERS" do
    ENV["ADMIN_USERS"] = "friend@example.test"
    sign_in

    post admin_invitations_path, params: invitation_params
    assert_response :created
    assert_select "strong", text: "Super Admin access:"
    assert_includes response.body, "will also have super administrator access"
    assert_not_includes response.body, "This account cannot invite or remove GigaAdmin administrators"

    link = css_select("input#invitation-link").first["value"]
    token = URI.decode_www_form(URI.parse(link).query).to_h.fetch("token")
    get accept_admin_invitation_path(token: token)
    assert_response :success
    assert_select "strong", text: "Super Admin access:"
  end

  test "invalid account passwords keep the invitation available for correction" do
    invitation, token = issue_invitation

    assert_no_difference "AdminUser.count" do
      post accept_admin_invitation_path(token: token), params: { admin_user: { password: "short", password_confirmation: "short" } }
    end

    assert_response :unprocessable_entity
    assert_select "[role='alert']"
    assert_nil invitation.reload.accepted_at
    assert_nil request.session[:local_admin_id]
  end

  test "an administrator can revoke a pending link" do
    invitation, token = issue_invitation
    sign_in

    delete admin_invitation_path(invitation)
    assert_redirected_to admin_users_path
    assert invitation.reload.revoked_at

    get accept_admin_invitation_path(token: token)
    assert_response :gone
  end

  test "expired and unknown links cannot create accounts" do
    invitation, token = issue_invitation
    travel_to(invitation.expires_at + 1.second) do
      assert_no_difference "AdminUser.count" do
        post accept_admin_invitation_path(token: token), params: { admin_user: { password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple" } }
      end
      assert_response :gone
    end

    get accept_admin_invitation_path(token: "a" * 64)
    assert_response :gone
  end

  test "Google authentication mode disables invitation acceptance" do
    invitation, token = issue_invitation
    sign_in
    ENV["GIGAADMIN_AUTH_MODE"] = "google"

    get accept_admin_invitation_path(token: token)
    assert_response :not_found
    assert_no_difference "AdminUser.count" do
      post accept_admin_invitation_path(token: token), params: { admin_user: { password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple" } }
    end
    assert_response :not_found
    assert_nil invitation.reload.accepted_at
  end

  test "Google administrators cannot issue or revoke local invitations" do
    invitation, = issue_invitation
    previous_admin_users = ENV["ADMIN_USERS"]
    previous_omniauth_mode = OmniAuth.config.test_mode
    previous_google_auth = OmniAuth.config.mock_auth[:google_oauth2]
    ENV["GIGAADMIN_AUTH_MODE"] = "google"
    ENV["ADMIN_USERS"] = "google-admin@example.test"
    OmniAuth.config.test_mode = true
    authentication = OmniAuth::AuthHash.new(provider: "google_oauth2", info: { email: "google-admin@example.test" })
    OmniAuth.config.mock_auth[:google_oauth2] = authentication
    post "/auth/google_oauth2/callback", env: { "omniauth.auth" => authentication }
    assert_redirected_to root_path

    assert_no_difference "AdminInvitation.count" do
      post admin_invitations_path, params: invitation_params
    end
    assert_response :not_found

    delete admin_invitation_path(invitation)
    assert_response :not_found
    assert_nil invitation.reload.revoked_at
  ensure
    ENV["ADMIN_USERS"] = previous_admin_users
    OmniAuth.config.test_mode = previous_omniauth_mode
    OmniAuth.config.mock_auth[:google_oauth2] = previous_google_auth
  end

  private

  def sign_in
    post local_sign_in_path, params: { session: { email: @admin.email, password: "correct-horse-battery-staple" } }
    assert_redirected_to root_path
  end

  def invitation_params
    { admin_invitation: { email: "friend@example.test" }, current_password: "correct-horse-battery-staple" }
  end

  def issue_invitation
    AdminInvitation.issue!(email: "friend@example.test", invited_by: @admin)
  end
end
