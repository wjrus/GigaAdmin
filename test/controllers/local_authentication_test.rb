require "test_helper"

class LocalAuthenticationTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-private-passphrase"

  setup do
    @original_environment = ENV.to_h.slice("GIGAADMIN_AUTH_MODE", "ADMIN_USERS", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GIGAADMIN_AUTH_MODE"] = "local"
    ENV["ADMIN_USERS"] = ""
  end

  teardown do
    %w[GIGAADMIN_AUTH_MODE ADMIN_USERS GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].each do |key|
      @original_environment.key?(key) ? ENV[key] = @original_environment[key] : ENV.delete(key)
    end
  end

  test "first visit leads to setup and creates a signed-in super admin only once" do
    get root_path
    assert_redirected_to setup_path
    get setup_path
    assert_response :success
    assert_select "aside", text: /grant or revoke library access/
    assert_select "form[action=?][data-turbo='false']", setup_path

    assert_difference "AdminUser.count", 1 do
      post setup_path, params: { admin_user: credentials }
    end
    assert_redirected_to root_path
    assert AdminUser.last.super_admin?
    get admin_users_path
    assert_response :success
    assert_select "form[action=?]", admin_invitations_path

    assert_no_difference "AdminUser.count" do
      post setup_path, params: { admin_user: credentials.merge(email: "intruder@example.com") }
    end
    assert_redirected_to sign_in_path
  end

  test "configured super admin list restricts the first claim" do
    ENV["ADMIN_USERS"] = "owner@example.com"
    assert_no_difference "AdminUser.count" do
      post setup_path, params: { admin_user: credentials.merge(email: "other@example.com") }
    end
    assert_response :unprocessable_entity
    post setup_path, params: { admin_user: credentials }
    assert_redirected_to root_path
  end

  test "a deferred page request cannot skip first-run setup" do
    get_content users_path

    assert_redirected_to setup_path
    follow_redirect! headers: { "Turbo-Frame" => "page-content" }
    assert_response :success
    assert_select "form[action=?]", setup_path
    assert_select "meta[name='turbo-visit-control'][content='reload']", count: 1
    assert_select "turbo-frame#page-content", count: 0
  end

  test "first page has a usable CSP nonce before a session already exists" do
    get setup_path
    assert_response :success
    nonce = css_select("script[type=module]").first["nonce"]
    assert nonce.present?
    assert_includes response.headers["Content-Security-Policy"], "'nonce-#{nonce}'"
    get setup_path
    assert_select "script[type=module][nonce=?]", nonce
  end

  test "invalid setup does not save a password or echo it" do
    assert_no_difference "AdminUser.count" do
      post setup_path, params: { admin_user: credentials.merge(password: "short", password_confirmation: "short") }
    end
    assert_response :unprocessable_entity
    assert_select "input[type=password][value]", count: 0
  end

  test "local sign in authenticates stored accounts independently of Google allowlist" do
    AdminUser.bootstrap(credentials)
    post local_sign_in_path, params: { session: { email: " OWNER@example.com ", password: "incorrect" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "Email or password is incorrect"
    assert_select "form[action=?][data-turbo='false']", local_sign_in_path
    post local_sign_in_path, params: { session: { email: " OWNER@example.com ", password: PASSWORD } }
    assert_redirected_to root_path
    get admin_users_path
    assert_response :success
    delete sign_out_path
    get admin_users_path
    assert_redirected_to sign_in_path
  end

  test "local and Google authentication cannot cross modes" do
    AdminUser.bootstrap(credentials)
    post "/auth/google_oauth2/callback", env: { "omniauth.auth" => { "info" => { "email" => "owner@example.com" } } }
    assert_response :not_found
    ENV["GIGAADMIN_AUTH_MODE"] = "google"
    get setup_path
    assert_response :not_found
    post local_sign_in_path, params: { session: { email: "owner@example.com", password: PASSWORD } }
    assert_response :not_found
  end

  test "automatic mode uses Google only with both credentials" do
    ENV["GIGAADMIN_AUTH_MODE"] = "auto"
    ENV.delete("GOOGLE_CLIENT_ID")
    ENV.delete("GOOGLE_CLIENT_SECRET")
    assert AdminAuthentication.local?
    ENV["GOOGLE_CLIENT_ID"] = "synthetic-client"
    assert AdminAuthentication.local?
    ENV["GOOGLE_CLIENT_SECRET"] = "synthetic-secret"
    assert_not AdminAuthentication.local?
    ENV["GIGAADMIN_AUTH_MODE"] = "invalid"
    assert_raises(ArgumentError) { AdminAuthentication.mode }
  end

  test "ordinary admins see their account but cannot manage other administrators" do
    owner = AdminUser.bootstrap(credentials)
    ordinary = AdminUser.create!(credentials.merge(email: "sharing@example.com"))
    sign_in(ordinary)
    get admin_users_path
    assert_response :success
    assert_select "form[action=?]", admin_invitations_path, count: 0
    assert_select "form[action=?]", admin_user_path(owner), count: 0
    assert_select "form[action=?]", admin_password_path
    assert_no_difference "AdminUser.count" do
      delete admin_user_path(owner), params: { current_password: PASSWORD }
    end
    assert_response :forbidden
  end

  test "super admins can remove a sharing admin and invalidate its sessions" do
    owner = AdminUser.bootstrap(credentials)
    ordinary = AdminUser.create!(credentials.merge(email: "sharing@example.com"))
    other = open_session
    other.post local_sign_in_path, params: { session: { email: ordinary.email, password: PASSWORD } }
    sign_in(owner)
    assert_difference "AdminUser.count", -1 do
      delete admin_user_path(ordinary), params: { current_password: PASSWORD }
    end
    other.get admin_users_path
    other.assert_redirected_to sign_in_path
    assert_no_difference "AdminUser.count" do
      delete admin_user_path(owner), params: { current_password: PASSWORD }
    end
  end

  test "super privileges from ADMIN_USERS are checked on every request" do
    AdminUser.bootstrap(credentials)
    admin = AdminUser.create!(credentials.merge(email: "delegated@example.com"))
    ordinary = AdminUser.create!(credentials.merge(email: "sharing@example.com"))
    ENV["ADMIN_USERS"] = admin.email
    sign_in(admin)
    get admin_users_path
    assert_select "form[action=?]", admin_invitations_path
    ENV["ADMIN_USERS"] = ""
    assert_no_difference "AdminUser.count" do
      delete admin_user_path(ordinary), params: { current_password: PASSWORD }
    end
    assert_response :forbidden
  end

  test "password changes require the current password and revoke other sessions" do
    owner = AdminUser.bootstrap(credentials)
    other = open_session
    other.post local_sign_in_path, params: { session: { email: owner.email, password: PASSWORD } }
    sign_in(owner)
    patch admin_password_path, params: { current_password: "incorrect", admin_user: { password: "new-private-passphrase", password_confirmation: "new-private-passphrase" } }
    assert_equal 0, owner.reload.session_version
    patch admin_password_path, params: { current_password: PASSWORD, admin_user: { password: "", password_confirmation: "" } }
    assert_equal 0, owner.reload.session_version
    patch admin_password_path, params: { current_password: PASSWORD, admin_user: { password: "new-private-passphrase", password_confirmation: "new-private-passphrase" } }
    assert_equal 1, owner.reload.session_version
    get admin_users_path
    assert_response :success
    other.get admin_users_path
    other.assert_redirected_to sign_in_path
  end

  test "password verification does not accept a matching bcrypt prefix with extra bytes" do
    password = "x" * 72
    AdminUser.bootstrap(credentials.merge(password: password, password_confirmation: password))
    post local_sign_in_path, params: { session: { email: "owner@example.com", password: password + "suffix" } }
    assert_response :unprocessable_entity
  end

  test "login refuses attempts when the configured rate limit is exceeded" do
    AdminUser.bootstrap(credentials)
    store = SessionsController.cache_store
    original_increment = store.method(:increment)
    store.define_singleton_method(:increment) { |*_, **_| 11 }
    post local_sign_in_path, params: { session: { email: "owner@example.com", password: PASSWORD } }
    assert_response :too_many_requests
    get admin_users_path
    assert_redirected_to sign_in_path
  ensure
    store.define_singleton_method(:increment, original_increment) if original_increment
  end

  test "first account creation requires CSRF protection" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    assert_no_difference "AdminUser.count" do
      post setup_path, params: { admin_user: credentials }
    end
    assert_response :unprocessable_entity
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  private

  def credentials
    { email: "owner@example.com", password: PASSWORD, password_confirmation: PASSWORD }
  end

  def sign_in(admin)
    post local_sign_in_path, params: { session: { email: admin.email, password: PASSWORD } }
    assert_redirected_to root_path
  end
end
