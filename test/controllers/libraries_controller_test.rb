require "test_helper"

class LibrariesControllerTest < ActionDispatch::IntegrationTest
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

  test "renders library detail page" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      library_title: "Movies",
      media_type: "movie",
      full_title: "Feature",
      duration: 1000,
      view_offset: 950,
      viewed_at: Time.zone.local(2026, 5, 24, 13, 0, 0)
    )

    get_content library_path("Movies")

    assert_response :success
    assert_select "h1", "Movies"
    assert_select "h2", "Shared Users"
    assert_select "div", text: "viewer"
    assert_select "h2", "Top Users"
    assert_select "td", text: "Feature"
  end

  test "shares one deduplication query across library statistics and recent stream ids" do
    attrs = { machine_identifier: "machine-one", library_title: "Movies", media_type: "movie", duration: 1000, view_offset: 950 }
    PlexStreamEvent.create!(attrs.merge(account_id: "42", rating_key: "one", title: "Older", viewed_at: 2.days.ago))
    PlexStreamEvent.create!(attrs.merge(account_id: "43", rating_key: "two", title: "Latest", viewed_at: Time.current))
    reads = []
    subscriber = ->(_name, _start, _finish, _id, payload) do
      reads << payload[:sql] if payload[:name] == "Plex usage statistics" || payload[:sql].match?(/\ASELECT .*plex_stream_events/im)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get_content library_path("Movies")
    end

    assert_response :success
    assert_select "td", text: "Latest"
    assert_equal 2, reads.size
    assert_equal 1, reads.count { |sql| sql.include?("DISTINCT ON") }
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
