require "test_helper"

class SharesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  FakeClient = Struct.new(:removed_share_id, :created_invite, :updated_share, :canceled_invite, :remaining_invites, :cancel_error) do
    def create_shared_server(_machine_identifier, invited_email, library_section_ids, allow_sync: false)
      self.created_invite = {
        invited_email: invited_email,
        library_section_ids: library_section_ids,
        allow_sync: allow_sync
      }
      %(<Invite id="invite-one" />)
    end

    def remove_shared_server(_machine_identifier, shared_server_id)
      self.removed_share_id = shared_server_id
    end

    def update_shared_server(_machine_identifier, shared_server_id, library_section_ids)
      self.updated_share = {
        shared_server_id: shared_server_id,
        library_section_ids: library_section_ids
      }
    end

    def cancel_requested_invite(invite_id, friend:, home:, server:)
      raise cancel_error if cancel_error

      self.canceled_invite = {
        invite_id: invite_id,
        friend: friend,
        home: home,
        server: server
      }
    end

    def server(_machine_identifier)
      {
        server: { name: "Local Plex" },
        sections: [ { id: "1", key: "1", title: "Movies", type: "movie" } ]
      }
    end

    def shared_servers(_machine_identifier)
      []
    end

    def users
      []
    end

    def requested_invites
      remaining_invites || []
    end
  end

  setup do
    @original_machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"]
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_admin_user = ENV["ADMIN_USER"]
    ENV["PLEX_MACHINE_IDENTIFIER"] = "machine-one"
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV.delete("ADMIN_USER")
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    ENV["PLEX_MACHINE_IDENTIFIER"] = @original_machine_identifier
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["ADMIN_USER"] = @original_admin_user
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "shares page renders library checkbox pills" do
    get root_path

    assert_response :success
    assert_select "input[type=checkbox][name='library_ids[]']"
    assert_select "select[name='library_ids[]']", count: 0
    assert_select "tr[role='link'][data-controller='row-link']"
    assert_select "a", text: "Open user", count: 0
  end

  test "shares page hides suppressed users" do
    PlexUserNote.find_or_create_by!(plex_user_id: "42").update!(suppressed: true)

    get root_path

    assert_response :success
    assert_select "td", text: "Viewer", count: 0
    assert_select "p", text: "0"
  end

  test "admin queues an async refresh" do
    assert_enqueued_with(job: PlexRefreshJob) do
      post refresh_shares_path
    end

    assert_redirected_to maintenance_path
    refresh_run = RefreshRun.latest_for("machine-one")
    assert_equal "queued", refresh_run.status
    assert_equal "admin@example.com", refresh_run.admin_email
    assert_not refresh_run.include_history
  end

  test "admin can include playback history in async refresh" do
    assert_enqueued_with(job: PlexRefreshJob) do
      post refresh_shares_path, params: { include_history: "1" }
    end

    refresh_run = RefreshRun.latest_for("machine-one")
    assert refresh_run.include_history
  end

  test "admin cannot queue duplicate refreshes" do
    RefreshRun.create!(machine_identifier: "machine-one", status: "running")

    assert_no_enqueued_jobs do
      post refresh_shares_path
    end

    assert_redirected_to maintenance_path
  end

  test "admin can invite a user to selected libraries" do
    client = FakeClient.new
    with_plex_client(client) do
      post shares_path, params: {
        invited_email: "friend@example.com",
        library_ids: [ "1" ],
        allow_sync: "1"
      }
    end

    assert_redirected_to user_path("invite-one")
    assert_equal(
      {
        invited_email: "friend@example.com",
        library_section_ids: [ "1" ],
        allow_sync: true
      },
      client.created_invite
    )
    pending_user = ShareSnapshot.latest_for("machine-one").users.first
    assert_equal "invite-one", pending_user["id"]
    assert_equal "friend@example.com", pending_user["email"]
    assert pending_user["pending"]
    assert_equal [ "Movies" ], pending_user["libraries"].map { |library| library["title"] }
    log = ShareAuditLog.recent.first
    assert_equal "library_access_granted", log.action
    assert_equal "admin@example.com", log.admin_email
    assert_equal "friend@example.com", log.target_label
    assert_equal [ "Movies" ], log.libraries_after
  end

  test "admin can remove a share" do
    client = FakeClient.new
    with_plex_client(client) { delete share_path("99") }

    assert_redirected_to root_path
    assert_equal "99", client.removed_share_id
    assert_empty ShareSnapshot.latest_for("machine-one").users
    log = ShareAuditLog.recent.first
    assert_equal "library_access_removed", log.action
    assert_equal "viewer", log.target_label
    assert_equal [ "Movies" ], log.libraries_removed
  end

  test "unknown shares cannot be removed through an unchecked remote request" do
    client = FakeClient.new
    with_plex_client(client) do
      assert_no_difference [ "ShareSnapshot.count", "ShareAuditLog.count" ] do
        delete share_path("unknown-share")
      end
    end

    assert_redirected_to root_path
    assert_nil client.removed_share_id
    assert_match "Share not found", flash[:alert]
  end

  test "unknown library selections cannot create an invite or diverge from the local audit" do
    client = FakeClient.new
    with_plex_client(client) do
      assert_no_difference [ "ShareSnapshot.count", "ShareAuditLog.count" ] do
        post shares_path, params: { invited_email: "friend@example.com", library_ids: [ "1", "missing" ] }
      end
    end

    assert_redirected_to root_path
    assert_nil client.created_invite
    assert_match "selected library", flash[:alert]
  end

  test "unknown and malformed library selections cannot mutate a share" do
    [ [ "1", "missing" ], { "nested" => "1" } ].each do |library_ids|
      client = FakeClient.new
      with_plex_client(client) do
        assert_no_difference [ "ShareSnapshot.count", "ShareAuditLog.count" ] do
          patch share_path("99"), params: { library_ids: library_ids, library_version: ShareSnapshot.library_version([ "1" ]) }
        end
      end

      assert_redirected_to root_path
      assert_nil client.updated_share
      assert_nil client.removed_share_id
      assert_match "Reload before saving", flash[:alert]
    end
  end

  test "successful invitation is logged and cached even when refresh fails" do
    client = FakeClient.new
    client.define_singleton_method(:server) { |_| raise Plex::Client::Error, "Synthetic timeout" }
    with_plex_client(client) do
      assert_difference "ShareAuditLog.count" do
        post shares_path, params: { invited_email: "viewer@example.com", library_ids: [ "1" ] }
      end
    end

    assert client.created_invite
    assert_redirected_to user_path("invite-one")
    assert_match "Invite sent", flash[:alert]
    assert ShareSnapshot.latest_for("machine-one").users.any? { |user| user["id"] == "invite-one" }
  end

  test "admin can update libraries and records changed libraries" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [
        { id: "1", key: "1", title: "Movies", type: "movie" },
        { id: "2", key: "2", title: "Theatre", type: "movie" }
      ],
      users: [
        {
          id: "42",
          share_id: "99",
          title: "Viewer",
          username: "viewer",
          email: "viewer@example.com",
          libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ],
          library_count: 1,
          all_libraries: false
        }
      ],
      fetched_at: Time.current
    )

    client = FakeClient.new
    with_plex_client(client) do
      patch share_path("99"), params: { library_ids: [ "2" ], library_version: ShareSnapshot.library_version([ "1" ]) }
    end

    assert_redirected_to root_path
    assert_equal({ shared_server_id: "99", library_section_ids: [ "2" ] }, client.updated_share)
    log = ShareAuditLog.recent.first
    assert_equal "libraries_changed", log.action
    assert_equal [ "Theatre" ], log.libraries_added
    assert_equal [ "Movies" ], log.libraries_removed
    assert_equal [ "Theatre" ], log.libraries_after
  end

  test "admin can bulk add a library" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [
        { id: "1", key: "1", title: "Movies", type: "movie" },
        { id: "2", key: "2", title: "Theatre", type: "movie" }
      ],
      users: [
        {
          id: "42",
          share_id: "99",
          title: "Viewer",
          username: "viewer",
          email: "viewer@example.com",
          pending: false,
          libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ],
          library_count: 1,
          all_libraries: false
        }
      ],
      fetched_at: Time.current
    )

    client = FakeClient.new
    with_plex_client(client) do
      post bulk_shares_path, params: { user_ids: [ "42" ], library_id: "2", operation: "add" }
    end

    assert_redirected_to users_path
    assert_equal({ shared_server_id: "99", library_section_ids: [ "1", "2" ] }, client.updated_share)
    log = ShareAuditLog.recent.first
    assert_equal "libraries_added", log.action
    assert_equal [ "Theatre" ], log.libraries_added
  end

  test "rejects a stale library form before calling Plex" do
    client = FakeClient.new
    with_plex_client(client) do
      patch share_path("99"), params: { library_ids: [ "1" ], library_version: ShareSnapshot.library_version([ "old-library" ]) }
    end
    assert_nil client.updated_share
    assert_match "Reload this user", flash[:alert]
  end

  test "admin can cancel pending invite with email id" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ],
      users: [
        {
          id: "pending@example.com",
          title: "Pending User",
          username: "pending",
          email: "pending@example.com",
          home: false,
          invite_friend: false,
          invite_server: true,
          pending: true,
          all_libraries: true,
          library_count: 1,
          libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ]
        }
      ],
      fetched_at: Time.current
    )

    client = FakeClient.new
    with_plex_client(client) { delete pending_invite_path("pending@example.com") }

    assert_redirected_to root_path
    assert_equal({ invite_id: "pending@example.com", friend: false, home: false, server: true }, client.canceled_invite)
    assert_empty ShareSnapshot.latest_for("machine-one").users
    log = ShareAuditLog.recent.first
    assert_equal "pending_invite_canceled", log.action
    assert_equal "pending", log.target_label
  end

  test "does not hide pending invite locally when Plex still reports it" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ],
      users: [
        {
          id: "pending@example.com",
          title: "Pending User",
          username: "pending",
          email: "pending@example.com",
          home: false,
          invite_friend: false,
          invite_server: true,
          pending: true,
          all_libraries: true,
          library_count: 1,
          libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ]
        }
      ],
      fetched_at: Time.current
    )

    client = FakeClient.new
    client.remaining_invites = [ { id: "pending@example.com", email: "pending@example.com" } ]
    with_plex_client(client) { delete pending_invite_path("pending@example.com") }

    assert_redirected_to root_path
    assert_equal "pending@example.com", ShareSnapshot.latest_for("machine-one").users.first["id"]
    assert_nil ShareAuditLog.find_by(action: "pending_invite_canceled")
    assert_equal "Plex still reports this pending invite after cancellation.", flash[:alert]
  end

  test "cleans stale local pending invite when Plex returns not found" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ],
      users: [
        {
          id: "pending@example.com",
          title: "Pending User",
          username: "pending",
          email: "pending@example.com",
          home: false,
          invite_friend: false,
          invite_server: true,
          pending: true,
          all_libraries: true,
          library_count: 1,
          libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ]
        }
      ],
      fetched_at: Time.current
    )

    client = FakeClient.new
    client.cancel_error = Plex::Client::Error.new("Plex API returned 404 for /api/invites/requested/pending%40example.com")
    with_plex_client(client) { delete pending_invite_path("pending@example.com") }

    assert_redirected_to root_path
    assert_empty ShareSnapshot.latest_for("machine-one").users
    assert_nil ShareAuditLog.find_by(action: "pending_invite_canceled")
    assert_equal "Pending Plex invite was already gone; local cache cleaned up.", flash[:notice]
  end

  private

  def with_plex_client(client)
    original_from_env = Plex::Client.method(:from_env)
    Plex::Client.define_singleton_method(:from_env) { client }
    yield
  ensure
    Plex::Client.define_singleton_method(:from_env, original_from_env)
  end

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
