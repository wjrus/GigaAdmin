require "test_helper"

class ShareAuditLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_admin_user = ENV["ADMIN_USER"]
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV.delete("ADMIN_USER")
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["ADMIN_USER"] = @original_admin_user
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "renders audit log entries" do
    get share_audit_logs_path

    assert_response :success
    assert_select "h1", "Log"
    assert_select "td", text: "admin@example.com"
    assert_select "td", text: /added Movies to Viewer/
  end

  test "filters audit log entries" do
    get share_audit_logs_path(action_type: "libraries_added", q: "Viewer")

    assert_response :success
    assert_select "td", text: /added Movies to Viewer/
  end

  test "filters destructive audit log entries" do
    ShareAuditLog.create!(
      action: "library_access_removed",
      admin_email: "admin@example.com",
      target_label: "Former Viewer",
      libraries_removed: [ "Movies" ]
    )

    get share_audit_logs_path(destructive: "1")

    assert_response :success
    assert_select "td", text: /removed Former Viewer from all libraries/
    assert_select "td", text: /added Movies to Viewer/, count: 0
  end

  test "invalid date filters return no entries instead of failing or widening the search" do
    [ { from: "not-a-date" }, { to: "not-a-date" }, { to: "2026-02-30" } ].each do |filter|
      get share_audit_logs_path(filter)

      assert_response :success
      assert_select "td", text: /added Movies to Viewer/, count: 0
    end
  end

  test "date filters include the full local end date and exclude the following day" do
    Time.use_zone("America/Detroit") do
      ShareAuditLog.create!(action: "user_note_updated", admin_email: "admin@example.com", target_label: "Late evening", created_at: Time.zone.local(2026, 5, 24, 23, 59, 59))
      ShareAuditLog.create!(action: "user_note_updated", admin_email: "admin@example.com", target_label: "Next morning", created_at: Time.zone.local(2026, 5, 25))

      get share_audit_logs_path(from: "2026-05-24", to: "2026-05-24")

      assert_response :success
      assert_select "td", text: /updated notes for Late evening/
      assert_select "td", text: /updated notes for Next morning/, count: 0
    end
  end

  test "exports audit log csv" do
    get share_audit_logs_path(format: :csv)

    assert_response :success
    assert_includes response.media_type, "text/csv"
    assert_includes response.body, "created_at,admin_email,action"
    assert_includes response.body, "libraries_added"
  end

  test "escapes spreadsheet formula prefixes in audit log csv" do
    ShareAuditLog.create!(
      action: "user_note_updated",
      admin_email: "admin@example.com",
      target_label: "=cmd",
      target_email: "@formula.example"
    )

    get share_audit_logs_path(format: :csv)

    assert_response :success
    assert_includes response.body, "'=cmd"
    assert_includes response.body, "'@formula.example"
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
