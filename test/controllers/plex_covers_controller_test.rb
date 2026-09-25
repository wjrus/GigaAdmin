require "test_helper"

class PlexCoversControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_admin_users = ENV["ADMIN_USERS"]
    @original_admin_user = ENV["ADMIN_USER"]
    @original_plex_token = ENV["PLEX_TOKEN"]
    @original_plex_server_base_url = ENV["PLEX_SERVER_BASE_URL"]
    ENV["ADMIN_USERS"] = "admin@example.com"
    ENV["PLEX_TOKEN"] = "token"
    ENV["PLEX_SERVER_BASE_URL"] = "http://plex.example:32400"
    ENV.delete("ADMIN_USER")
    OmniAuth.config.test_mode = true
    sign_in
  end

  teardown do
    ENV["ADMIN_USERS"] = @original_admin_users
    ENV["ADMIN_USER"] = @original_admin_user
    ENV["PLEX_TOKEN"] = @original_plex_token
    ENV["PLEX_SERVER_BASE_URL"] = @original_plex_server_base_url
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "proxies Plex cover art through the Rails app" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Type"] = "image/jpeg"
    response.instance_variable_set(:@body, "jpeg-bytes")
    response.instance_variable_set(:@read, true)
    response.define_singleton_method(:read_body) { |&block| block.call("jpeg-bytes") }
    fake_http = Class.new do
      define_method(:request) do |request, &block|
        raise "missing Plex token" unless request.uri.query.include?("X-Plex-Token=token")
        raise "wrong cover path" unless request.uri.path == "/library/metadata/1/thumb/123"

        block.call(response)
      end
    end.new

    original_start = Net::HTTP.method(:start)
    begin
      Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
        block.call(fake_http)
      end

      get plex_cover_path(path: "/library/metadata/1/thumb/123")

      assert_response :success
      assert_equal "image/jpeg", @response.media_type
      assert_equal "jpeg-bytes", @response.body
    ensure
      Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
        original_start.call(*args, **kwargs, &block)
      end
    end
  end

  test "rejects unsupported cover paths" do
    get plex_cover_path(path: "/status/sessions")

    assert_response :not_found
  end

  test "rejects metadata traversal and non-artwork endpoints without contacting Plex" do
    paths = [
      "/library/metadata/1",
      "/library/metadata/../../status/sessions",
      "/library/metadata/1/thumb/../../../../status/sessions",
      "/library/metadata/1/thumb/%2e%2e/%2e%2e/status/sessions",
      "/photo/:/transcode/../status/sessions"
    ]
    paths.each do |path|
      with_cover_response(nil, on_request: ->(_) { flunk "Plex must not receive #{path}" }) do
        get plex_cover_path(path: path)
      end
      assert_response :not_found
    end
  end

  test "rejects transcode URLs outside local artwork without contacting Plex" do
    sources = [
      "http://other.example/library/metadata/1/thumb/123",
      "http://127.0.0.1:32400/library/metadata/1/thumb/123",
      "//other.example/library/metadata/1/thumb/123",
      "file:///etc/passwd",
      "/status/sessions",
      "/library/metadata/1/thumb/../../../status/sessions",
      "/library/metadata/1/thumb/123?url=http://other.example"
    ]
    sources.each do |source|
      path = "/photo/:/transcode?#{URI.encode_www_form(url: source, width: 300)}"
      with_cover_response(nil, on_request: ->(_) { flunk "Plex must not receive #{source}" }) do
        get plex_cover_path(path: path)
      end
      assert_response :not_found
    end
  end

  test "rejects missing and ambiguous transcode sources" do
    [ "width=300", "url=%2Flibrary%2Fmetadata%2F1%2Fthumb&url=http%3A%2F%2Fother.example" ].each do |query|
      with_cover_response(nil, on_request: ->(_) { flunk "Plex must not receive an ambiguous source" }) do
        get plex_cover_path(path: "/photo/:/transcode?#{query}")
      end
      assert_response :not_found
    end
  end

  test "proxies local transcodes while replacing untrusted token parameters" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Type"] = "image/jpeg"
    response.define_singleton_method(:read_body) { |&block| block.call("jpeg-bytes") }
    [ "/library/metadata/1/thumb/123", "http://plex.example:32400/library/metadata/1/thumb/123" ].each do |source|
      query = URI.encode_www_form(url: source, width: 300, "x-plex-token" => "untrusted")
      request_uri = nil
      with_cover_response(response, on_request: ->(request) { request_uri = request.uri }) do
        get plex_cover_path(path: "/photo/:/transcode?#{query}")
      end
      assert_response :success
      assert_equal "/photo/:/transcode", request_uri.path
      assert_equal [ [ "url", "/library/metadata/1/thumb/123" ], [ "width", "300" ], [ "X-Plex-Token", "token" ] ], URI.decode_www_form(request_uri.query)
    end
  end

  test "rejects svg cover responses" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Type"] = "image/svg+xml"
    response.instance_variable_set(:@body, "<svg></svg>")
    response.instance_variable_set(:@read, true)
    fake_http = Class.new do
      define_method(:request) { |_request, &block| block.call(response) }
    end.new

    original_start = Net::HTTP.method(:start)
    begin
      Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
        block.call(fake_http)
      end

      get plex_cover_path(path: "/library/metadata/1/thumb/123")

      assert_response :not_found
    ensure
      Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
        original_start.call(*args, **kwargs, &block)
      end
    end
  end

  test "rejects oversized declared content before reading it" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Type"] = "image/jpeg"
    response["Content-Length"] = (PlexCoversController::MAX_COVER_BYTES + 1).to_s
    response.define_singleton_method(:read_body) { raise "Body should not be read" }
    with_cover_response(response) { get plex_cover_path(path: "/library/metadata/1/thumb/123") }
    assert_response :not_found
  end

  test "aborts chunked covers at the byte limit without draining the response" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Type"] = "image/jpeg"
    chunks_read = 0
    response.define_singleton_method(:read_body) do |&block|
      [ "x" * PlexCoversController::MAX_COVER_BYTES, "x", "never-read" ].each do |chunk|
        chunks_read += 1
        block.call(chunk)
      end
    end
    with_cover_response(response) { get plex_cover_path(path: "/library/metadata/1/thumb/123") }
    assert_response :not_found
    assert_equal 2, chunks_read
  end

  private

  def with_cover_response(response, on_request: nil)
    http = Object.new
    http.define_singleton_method(:request) do |request, &block|
      on_request&.call(request)
      block.call(response)
    end
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_, **_, &block| block.call(http) }
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original)
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
