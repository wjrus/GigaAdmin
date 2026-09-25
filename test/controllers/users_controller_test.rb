require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"]
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_admin_user = ENV["ADMIN_USER"]
    @original_owner_account_id = ENV["PLEX_OWNER_ACCOUNT_ID"]
    @original_owner_name = ENV["PLEX_OWNER_NAME"]
    @original_owner_username = ENV["PLEX_OWNER_USERNAME"]
    @original_owner_email = ENV["PLEX_OWNER_EMAIL"]
    travel_to Time.zone.local(2026, 5, 26, 12, 0, 0)
    ENV["PLEX_MACHINE_IDENTIFIER"] = "machine-one"
    ENV["ADMIN_USERS"] = "admin@example.com, coadmin@example.com"
    ENV.delete("ADMIN_USER")
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    ENV["PLEX_MACHINE_IDENTIFIER"] = @original_machine_identifier
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["ADMIN_USER"] = @original_admin_user
    ENV["PLEX_OWNER_ACCOUNT_ID"] = @original_owner_account_id
    ENV["PLEX_OWNER_NAME"] = @original_owner_name
    ENV["PLEX_OWNER_USERNAME"] = @original_owner_username
    ENV["PLEX_OWNER_EMAIL"] = @original_owner_email
    travel_back
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "sorts users by name ascending by default" do
    get users_path

    assert_response :success
    assert_select "a[aria-label*='Name, sorted ascending']"
  end

  test "sorts users by last streamed descending" do
    get users_path(sort: "last_streamed", direction: "desc")

    assert_response :success
    assert_select "a[aria-label*='Last Streamed, sorted descending']"
  end

  test "users without playback stay last in either last-streamed sort direction" do
    snapshot = share_snapshots(:one)
    template = snapshot.users.first
    snapshot.update!(users: [
      template.merge("id" => "never", "username" => "Never played", "last_streamed_at" => nil),
      template.merge("id" => "older", "username" => "Older playback", "last_streamed_at" => 2.days.ago.to_i),
      template.merge("id" => "recent", "username" => "Recent playback", "last_streamed_at" => 1.day.ago.to_i)
    ])

    {
      "asc" => [ "Older playback", "Recent playback", "Never played" ],
      "desc" => [ "Recent playback", "Older playback", "Never played" ]
    }.each do |direction, expected_names|
      get users_path(sort: "last_streamed", direction: direction)

      assert_response :success
      assert_select "tbody tr td:first-child" do |cells|
        assert_equal expected_names, cells.map { |cell| cell.text.strip }
      end
    end
  end

  test "loads latest local history for all accounts with one query" do
    8.times do |index|
      %w[Older Latest].each_with_index do |label, offset|
        PlexStreamEvent.create!(
          machine_identifier: "machine-one",
          account_id: "local-#{index}",
          viewed_at: 2.days.ago + offset.hours,
          full_title: "#{label} local stream #{index}",
          media_type: "movie"
        )
      end
    end
    PlexStreamEvent.create!(machine_identifier: "other-machine", account_id: "foreign-user", viewed_at: Time.current, full_title: "Foreign stream")
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) do
      queries << payload[:sql] if payload[:sql].match?(/SELECT.*FROM "plex_stream_events"/m)
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get users_path(q: "local-")
    end

    assert_response :success
    assert_equal 1, queries.size, queries.join("\n")
    assert_select "p", text: "8 users shown"
    assert_select "td", text: /Latest local stream 0/
    assert_select "td", text: /Older local stream/, count: 0
    assert_select "td", text: /Foreign stream/, count: 0
  end

  test "shows user details" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [
        { id: "1", key: "1", title: "Movies", type: "movie" },
        { id: "2", key: "2", title: "TV Shows", type: "show" }
      ],
      users: [
        {
          id: "42",
          share_id: "99",
          title: "Viewer",
          username: "viewer",
          email: "viewer@example.com",
          pending: false,
          all_libraries: true,
          library_count: 2,
          libraries: [
            { id: "1", key: "1", title: "Movies", type: "movie" },
            { id: "2", key: "2", title: "TV Shows", type: "show" }
          ]
        }
      ],
      fetched_at: Time.current
    )
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      viewed_at: Time.zone.local(2026, 5, 24, 12, 0, 0),
      full_title: "Taskmaster - The Noise That Blue Makes",
      library_title: "TV Shows",
      media_type: "episode",
      player_title: "Apple TV",
      player_platform: "tvOS",
      ip_address: "192.0.2.10"
    )
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      viewed_at: Time.zone.local(2026, 5, 24, 13, 0, 0),
      title: "The Nice Guys",
      full_title: "The Nice Guys",
      library_title: "Movies",
      media_type: "movie",
      duration: 1000,
      view_offset: 950
    )
    PlexNowPlayingSample.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      sampled_at: Time.zone.local(2026, 5, 24, 12, 5, 0),
      full_title: "Taskmaster - The Noise That Blue Makes",
      state: "playing",
      player_title: "Bedroom TV",
      player_platform: "tvOS",
      ip_address: "192.0.2.11",
      progress_percent: 42
    )

    get user_path("42")

    assert_response :success
    assert_select "h1", "viewer"
    assert_select "h2", "Library Access"
    assert_select "h2", "Activity"
    assert_select "h2", "Type Mix"
    assert_select "h2", "Top Series"
    assert_select "h2", "Top Movies"
    assert_select "a[aria-current='page']", "7 days"
    assert_select "a", "30 days"
    assert_select "a", "Past year"
    assert_select "a", "All time"
    assert_select "h2", "Stream History"
    assert_select "h2", "Recent Live Sessions"
    assert_select "span", text: "Taskmaster"
    assert_select "span", text: "The Nice Guys"
    assert_select "input[name='stream_q']"
    assert_select "select[name='stream_type']"
    assert_select "td", text: "Taskmaster - The Noise That Blue Makes"
    assert_select "th", text: "Player"
    assert_select "th", text: "IP Address"
    assert_select "th", text: "Library", count: 0
    assert_select "td", text: "Apple TV · tvOS"
    assert_select "td", text: "192.0.2.10"
    assert_select "td", text: "Bedroom TV · tvOS"
    assert_select "td", text: "192.0.2.11"
    assert_select "dialog.confirmation-dialog"
    assert_select "input[type=checkbox][name='library_ids[]']"
    assert_select "textarea[name='plex_user_note[notes]']"
    assert_select "button", "Remove user from Plex shares"
  end

  test "hides player and ip history columns when there is no stored data" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      viewed_at: Time.zone.local(2026, 5, 24, 12, 0, 0),
      full_title: "Taskmaster - The Noise That Blue Makes",
      media_type: "episode"
    )

    get user_path("42")

    assert_response :success
    assert_select "td", text: "Taskmaster - The Noise That Blue Makes"
    assert_select "th", text: "Player", count: 0
    assert_select "th", text: "IP Address", count: 0
    assert_select "td", text: "Unknown", count: 0
  end

  test "includes local history accounts that are not shared users" do
    ENV["PLEX_OWNER_ACCOUNT_ID"] = "owner-one"
    ENV["PLEX_OWNER_NAME"] = "Server Owner"
    ENV["PLEX_OWNER_USERNAME"] = "owner"
    ENV["PLEX_OWNER_EMAIL"] = "owner@example.com"

    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "owner-one",
      viewed_at: Time.zone.local(2026, 5, 24, 13, 0, 0),
      full_title: "Columbo - Murder by the Book",
      library_title: "TV Shows",
      media_type: "episode"
    )
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "owner-one",
      viewed_at: Time.zone.local(2026, 5, 24, 14, 0, 0),
      full_title: "Columbo - Playback",
      library_title: "Movies",
      media_type: "movie",
      duration: 1000,
      view_offset: 950
    )

    get users_path(q: "owner")

    assert_response :success
    assert_select "td", text: "owner"
    assert_select "td", text: "owner@example.com"
    assert_select "span", text: "Local history"
    assert_select "p", text: "1 user shown"

    get user_path("owner-one")

    assert_response :success
    assert_select "h1", "owner"
    assert_select "dd", text: "Local history only"
    assert_select "dd", text: "1"
    assert_select "span", text: "movie"
    assert_select "p", text: /not a shared-library user/
    assert_select "td", text: "Columbo - Murder by the Book"
  end

  test "can suppress and restore local history users" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "old-account",
      viewed_at: Time.zone.local(2026, 5, 24, 13, 0, 0),
      full_title: "Old Stream",
      media_type: "movie"
    )

    get users_path(q: "old-account")
    assert_response :success
    assert_select "td", text: "Account old-account"

    patch user_suppression_path("old-account"), params: { suppressed: "1", return_to: user_path("old-account") }
    assert_redirected_to user_path("old-account")

    note = PlexUserNote.find_by!(plex_user_id: "old-account")
    assert note.suppressed?
    assert_equal "admin@example.com", note.suppressed_by

    log = ShareAuditLog.find_by!(action: "user_suppressed", plex_user_id: "old-account")
    assert_equal "user_suppressed", log.action
    assert_equal "suppressed old-account", log.summary

    get users_path(q: "old-account")
    assert_response :success
    assert_select "td", text: "Account old-account", count: 0
    assert_select "p", text: /1 suppressed user/
    assert_select "a", text: "View suppressed"

    get users_path(status: "suppressed", q: "old-account")
    assert_response :success
    assert_select "td", text: "Account old-account"
    assert_select "span", text: "Suppressed"

    patch user_suppression_path("old-account"), params: { suppressed: "0", return_to: user_path("old-account") }
    assert_redirected_to user_path("old-account")
    assert_not note.reload.suppressed?
  end

  test "paginates stream history in a turbo frame" do
    30.times do |index|
      PlexStreamEvent.create!(
        machine_identifier: "machine-one",
        account_id: "42",
        viewed_at: Time.zone.local(2026, 5, 24, 12, 0, 0) - index.minutes,
        full_title: "History Item #{index + 1}",
        library_title: "Movies",
        media_type: "movie"
      )
    end

    get user_path("42")

    assert_response :success
    assert_select "turbo-frame#stream_history"
    assert_select "p", text: /Showing 1-25 of 30/
    assert_select "td", text: "History Item 1"
    assert_select "td", text: "History Item 26", count: 0
    assert_select "a[data-turbo-frame='stream_history']", text: "Next"

    get user_path("42", stream_page: 2)

    assert_response :success
    assert_select "p", text: /Showing 26-30 of 30/
    assert_select "td", text: "History Item 26"
    assert_select "td", text: "History Item 1", count: 0
    assert_select "a[data-turbo-frame='stream_history']", text: "Previous"
  end

  test "filters stream history and exports filtered csv" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      viewed_at: Time.zone.local(2026, 5, 24, 12, 0, 0),
      full_title: "Movie Match",
      library_title: "Movies",
      media_type: "movie"
    )
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      viewed_at: Time.zone.local(2026, 5, 23, 12, 0, 0),
      full_title: "Episode Miss",
      library_title: "TV Shows",
      media_type: "episode"
    )

    get user_path("42", stream_q: "match", stream_type: "movie")

    assert_response :success
    assert_select "td", text: "Movie Match"
    assert_select "td", text: "Episode Miss", count: 0
    assert_select "p", text: /Showing 1-1 of 1/
    assert_select "a[href*='stream_q=match'][href*='format=csv']", text: "Export CSV"

    get user_path("42", stream_q: "match", stream_type: "movie", format: :csv)

    assert_response :success
    assert_includes @response.body, "Movie Match"
    assert_not_includes @response.body, "Episode Miss"
  end

  test "filters users by search and notes" do
    get users_path(q: "viewer", notes: "with")

    assert_response :success
    assert_select "td", text: "viewer@example.com"
    assert_select "td", text: /Existing local note/
    assert_select "td", text: /Has notes/
    assert_select "td", text: /1 log event/
    assert_select "textarea[name='plex_user_note[notes]']", count: 0
    assert_select "button", text: "Apply to selected", count: 0
    assert_select "input[name='user_ids[]']", count: 0
    assert_select "tr[role='link'][data-controller='row-link']"
    assert_select "p", text: "1 user shown"
  end

  test "shows empty filtered state" do
    get users_path(q: "not-a-real-user")

    assert_response :success
    assert_select "p", text: "No users match those filters."
  end

  test "highlights pending invites" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ],
      users: [
        {
          id: "pending-one",
          title: "Pending Friend",
          username: "pending",
          email: "pending@example.com",
          pending: true,
          library_count: 1,
          libraries: []
        }
      ],
      fetched_at: Time.current
    )

    get users_path

    assert_response :success
    assert_select "h2", "Pending Invites"
    assert_select "p", text: /pending/
    assert_select "a", text: "View pending"
  end

  test "opens pending invite detail by email address" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [ { id: "1", key: "1", title: "Movies", type: "movie" } ],
      users: [
        {
          id: "invite-one",
          title: "Plex Test",
          username: "plextest",
          email: "plextest@wjr.us",
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

    get "/users/plextest@wjr.us"

    assert_response :success
    assert_select "h1", "plextest"
    assert_select "span", text: "Pending"
    assert_select "button", "Cancel invite"
  end

  test "caches a pending invite from Plex when opening detail by email address" do
    client = Object.new
    client.define_singleton_method(:requested_invites) do
      [
        {
          id: "invite-one",
          username: "plextest",
          email: "plextest@wjr.us",
          friendly_name: "Plex Test",
          created_at: "1704307031",
          server: "1",
          home: "0",
          friend: "0",
          servers: [ { name: "Local Plex", machine_identifier: "machine-one", num_libraries: "1" } ]
        }
      ]
    end

    with_plex_client(client) do
      get "/users/plextest@wjr.us"
    end

    assert_response :success
    assert_select "h1", "plextest"
    assert_select "button", "Cancel invite"
    pending_user = ShareSnapshot.latest_for("machine-one").users.find { |user| user["id"] == "invite-one" }
    assert_equal "plextest@wjr.us", pending_user["email"]
    assert pending_user["pending"]
  end

  test "exports users csv" do
    get users_path(format: :csv)

    assert_response :success
    assert_includes @response.media_type, "text/csv"
    assert_includes @response.body, "name,username,email,status"
    assert_includes @response.body, "viewer,viewer,viewer@example.com,accepted"
  end

  test "escapes spreadsheet formula prefixes in users csv" do
    ShareSnapshot.create!(
      machine_identifier: "machine-one",
      server: { name: "Local Plex" },
      libraries: [],
      users: [
        {
          id: "formula-user",
          title: "=cmd",
          username: "=cmd",
          email: "+formula@example.com",
          pending: false,
          library_count: 0,
          libraries: []
        }
      ],
      fetched_at: Time.current
    )

    get users_path(format: :csv)

    assert_response :success
    assert_includes @response.body, "'=cmd"
    assert_includes @response.body, "'+formula@example.com"
  end

  test "admin can save local notes for a Plex user" do
    patch user_note_path("42"), params: {
      plex_user_note: {
        username: "viewer",
        email: "viewer@example.com",
        notes: "Keep an eye on shared access."
      }
    }

    assert_redirected_to users_path(sort: nil, direction: nil)

    note = PlexUserNote.find_by!(plex_user_id: "42")
    assert_equal "Keep an eye on shared access.", note.notes
    assert_equal "admin@example.com", note.last_edited_by

    log = ShareAuditLog.find_by!(action: "user_note_updated", plex_user_id: "42")
    assert_equal "user_note_updated", log.action
    assert_equal "viewer", log.target_label
    assert_equal "admin@example.com", log.admin_email
    assert_equal "updated notes for viewer", log.summary
  end

  test "note changes roll back if audit recording fails" do
    note = PlexUserNote.find_or_create_by!(plex_user_id: "42")
    note.update!(notes: "Original note")
    original_record = ShareAuditLog.method(:record!)
    ShareAuditLog.define_singleton_method(:record!) { |**_| raise ActiveRecord::RecordInvalid }

    patch user_note_path("42"), params: { plex_user_note: { notes: "Changed note" } }
    assert_equal "Original note", note.reload.notes
  ensure
    ShareAuditLog.define_singleton_method(:record!, original_record)
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
