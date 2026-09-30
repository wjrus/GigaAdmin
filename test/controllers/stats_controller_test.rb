require "test_helper"

class StatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_machine_identifier = ENV["PLEX_MACHINE_IDENTIFIER"]
    travel_to Time.zone.local(2026, 5, 26, 12, 0, 0)
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV["PLEX_MACHINE_IDENTIFIER"] = "machine-one"
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["PLEX_MACHINE_IDENTIFIER"] = @original_machine_identifier
    travel_back
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "renders playback stats" do
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
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      library_title: "TV Shows",
      media_type: "episode",
      full_title: "Episode",
      duration: 1000,
      view_offset: 920,
      viewed_at: Time.zone.local(2026, 5, 25, 13, 0, 0)
    )

    get stats_path

    assert_response :success
    assert_select "h1", "Stats"
    assert_select "a[aria-current='page']", "Last week"
    assert_select "a", "Last day"
    assert_select "a", "Last month"
    assert_select "a", "Last 3 months"
    assert_select "a", "Last 6 months"
    assert_select "a", "Last year"
    assert_select "a", "All time"
    assert_select "h2", "Library Activity"
    assert_select "span", text: "Movies"
    assert_select "h2", "Top 10 Users"
    assert_select "h2", "Top 10 Movies"
    assert_select "h2", "Top 10 Shows"
    assert_select "h2", "Activity"
  end

  test "filters playback stats by selected period" do
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      library_title: "Movies",
      media_type: "movie",
      full_title: "Recent Feature",
      duration: 1000,
      view_offset: 950,
      viewed_at: Time.zone.local(2026, 5, 25, 13, 0, 0)
    )
    PlexStreamEvent.create!(
      machine_identifier: "machine-one",
      account_id: "42",
      library_title: "Movies",
      media_type: "movie",
      full_title: "Older Feature",
      duration: 1000,
      view_offset: 950,
      viewed_at: Time.zone.local(2026, 4, 1, 13, 0, 0)
    )

    get stats_path

    assert_response :success
    assert_select "p", text: "1"

    get stats_path(period: "all")

    assert_response :success
    assert_select "a[aria-current='page']", "All time"
    assert_select "p", text: "2"
  end

  test "all time charts do not instantiate event records" do
    PlexStreamEvent.create!(machine_identifier: "machine-one", account_id: "42", library_title: "Movies",
      media_type: "movie", duration: 1000, view_offset: 950, viewed_at: Time.current)
    instantiated = 0
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*args|
      payload = args.last
      instantiated += payload[:record_count] if payload[:class_name] == "PlexStreamEvent"
    end
    get stats_path(period: "all")
    assert_response :success
    assert_equal 0, instantiated
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "show rankings combine different episodes by show identity and support legacy titles" do
    enable_tv_library
    create_play(media_type: "episode", library_title: "TV Shows", rating_key: "episode-1", title: "Pilot",
      metadata: { grandparent_rating_key: "show-1", grandparent_title: "Space Show" })
    create_play(media_type: "episode", library_title: "TV Shows", rating_key: "episode-2", title: "Second Episode",
      metadata: { grandparent_rating_key: "show-1", grandparent_title: "Space Show" })
    create_play(media_type: "episode", library_title: "TV Shows", rating_key: "episode-3", title: "Pilot",
      metadata: { grandparent_rating_key: "show-2", grandparent_title: "Different Show" })
    create_play(media_type: "episode", library_title: "TV Shows", rating_key: "legacy-1", full_title: "Legacy Show - Season 1 - Pilot")
    create_play(media_type: "episode", library_title: "TV Shows", rating_key: "legacy-2", full_title: "Legacy Show - Season 2 - Finale")

    get stats_path

    assert_response :success
    assert_select "#top-shows li", count: 3
    assert_select "#top-shows li", text: /Space Show.*2 plays/m
    assert_select "#top-shows li", text: /Legacy Show.*2 plays/m
    assert_select "#top-shows li", text: /Different Show.*1 plays/m
    assert_select "#top-shows", text: /Second Episode/, count: 0
  end

  test "movie rankings preserve distinct rating IDs and separate missing IDs by title" do
    create_play(rating_key: "movie-1", title: "Same Title", account_id: "1")
    create_play(rating_key: "movie-1", title: "Same Title", account_id: "2")
    create_play(rating_key: "movie-2", title: "Same Title", account_id: "3")
    create_play(rating_key: nil, title: "Legacy Alpha", account_id: "4")
    create_play(rating_key: "", title: "Legacy Beta", account_id: "5")
    create_play(rating_key: nil, title: "Legacy Alpha", account_id: "6")

    get stats_path

    assert_response :success
    assert_select "#top-movies li", count: 4
    assert_select "#top-movies li", text: /Same Title.*2 plays/m
    assert_select "#top-movies li", text: /Same Title.*1 plays/m
    assert_select "#top-movies li", text: /Legacy Alpha.*2 plays/m
    assert_select "#top-movies li", text: /Legacy Beta.*1 plays/m
  end

  test "rankings limit all categories to ten and sort by counted plays" do
    enable_tv_library
    12.times do |index|
      create_play(account_id: "movie-viewer-#{index}", rating_key: "movie-#{index}", title: "Movie #{index}")
      create_play(account_id: "show-viewer-#{index}", media_type: "episode", library_title: "TV Shows",
        rating_key: "episode-#{index}", metadata: { grandparent_rating_key: "show-#{index}", grandparent_title: "Show #{index}" })
    end
    create_play(account_id: "42", rating_key: "winner-movie-1", title: "Winning Movie")
    create_play(account_id: "42", rating_key: "winner-movie-2", title: "Another Movie")
    create_play(account_id: "another-viewer", rating_key: "winner-movie-1", title: "Winning Movie")
    2.times do |index|
      create_play(account_id: "42", media_type: "episode", library_title: "TV Shows", rating_key: "winner-episode-#{index}",
        metadata: { grandparent_rating_key: "winner-show", grandparent_title: "Winning Show" })
    end

    get stats_path

    assert_response :success
    assert_select "#top-movies li", count: 10
    assert_select "#top-movies li:first-child", text: /Winning Movie.*2 plays/m
    assert_select "#top-shows li", count: 10
    assert_select "#top-shows li:first-child", text: /Winning Show.*2 plays/m
    assert_select "#top-users a", count: 10
    assert_select "#top-users a:first-child[href='#{user_path('42')}']", text: /viewer.*4 plays/m
  end

  test "each rolling period includes its exact lower boundary and excludes earlier and future events" do
    { "24h" => 24, "7d" => 168, "30d" => 720, "90d" => 2160, "180d" => 4320, "1y" => 8760 }.each do |period, hours|
      PlexStreamEvent.delete_all
      boundary = Time.current - hours.hours
      create_play(rating_key: "at-boundary", title: "At boundary", viewed_at: boundary)
      create_play(rating_key: "outside", title: "Outside window", viewed_at: boundary - 1.second)
      create_play(rating_key: "future", title: "Future clock", viewed_at: Time.current + 1.second)

      get stats_path(period: period)

      assert_response :success
      assert_select "#top-movies li", count: 1
      assert_select "#top-movies li", text: /At boundary/
    end
  end

  test "rankings respect completion library machine and duplicate play boundaries" do
    create_play(rating_key: "valid", title: "Valid Movie")
    create_play(rating_key: "valid", title: "Valid Movie", viewed_at: 1.minute.ago)
    create_play(rating_key: "incomplete", title: "Incomplete", view_offset: 300)
    create_play(rating_key: "inactive", title: "Inactive Library", library_title: "Removed Movies")
    create_play(rating_key: "other-machine", title: "Other Machine", machine_identifier: "machine-two")

    get stats_path(period: "invalid")

    assert_response :success
    assert_select "a[aria-current=page]", text: "Last week"
    assert_select "#top-movies li", count: 1
    assert_select "#top-movies li", text: /Valid Movie.*1 plays/m
  end

  private

  def create_play(**attributes)
    PlexStreamEvent.create!({ machine_identifier: "machine-one", account_id: "42", library_title: "Movies",
      media_type: "movie", duration: 1000, view_offset: 950, viewed_at: Time.current }.merge(attributes))
  end

  def enable_tv_library
    snapshot = share_snapshots(:one)
    snapshot.update!(libraries: snapshot.libraries + [ { id: "2", key: "2", title: "TV Shows", type: "show" } ])
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
