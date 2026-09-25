require "test_helper"

module Plex
  class ClientTest < ActiveSupport::TestCase
    test "parses current playback sessions with user and player details" do
      xml = <<~XML
        <MediaContainer size="1">
          <Video title="Episode" grandparentTitle="Show" type="episode" duration="1000" viewOffset="250" librarySectionTitle="TV Shows">
            <User id="42" title="Viewer" />
            <Player title="Apple TV" platform="tvOS" state="playing" />
            <Session id="session-one" />
          </Video>
        </MediaContainer>
      XML
      client = Client.new(token: "token", server_base_url: "http://plex.example")

      session = client.send(:session_document, xml).first

      assert_equal "Episode", session[:title]
      assert_equal "Viewer", session.dig(:user, :title)
      assert_equal "Apple TV", session.dig(:player, :title)
      assert_equal "session-one", session.dig(:session, :id)
    end

    test "parses playback history metadata with user and player details" do
      xml = <<~XML
        <MediaContainer size="1">
          <Video title="Feature" type="movie" viewedAt="1779649200" accountID="42" ratingKey="abc">
            <User id="42" title="Viewer" />
            <Player title="Apple TV" platform="tvOS" address="192.0.2.10" />
            <Media id="1" videoCodec="h264">
              <Part id="2" file="/media/feature.mkv" />
            </Media>
          </Video>
        </MediaContainer>
      XML
      client = Client.new(token: "token", server_base_url: "http://plex.example")

      history = client.send(:media_container, xml)[:metadata].first

      assert_equal "Feature", history[:title]
      assert_equal "42", history[:account_id]
      assert_equal "Viewer", history.dig(:user, :title)
      assert_equal "Apple TV", history.dig(:player, :title)
      assert_equal "tvOS", history.dig(:player, :platform)
      assert_equal "192.0.2.10", history.dig(:player, :address)
      assert_equal "h264", history.dig(:media, :video_codec)
      assert_equal "/media/feature.mkv", history.dig(:media, :part, :file)
    end

    test "parses json metadata with nested details" do
      payload = {
        "MediaContainer" => {
          "Metadata" => [
            {
              "title" => "Feature",
              "accountID" => "42",
              "Player" => { "title" => "Apple TV", "platform" => "tvOS" },
              "Media" => [
                { "videoCodec" => "h264", "Part" => [ { "file" => "/media/feature.mkv" } ] }
              ]
            }
          ]
        }
      }
      client = Client.new(token: "token", server_base_url: "http://plex.example")

      history = client.send(:media_container, JSON.generate(payload))[:metadata].first

      assert_equal "42", history[:account_id]
      assert_equal "Apple TV", history.dig(:player, :title)
      assert_equal "h264", history.dig(:media, 0, :video_codec)
      assert_equal "/media/feature.mkv", history.dig(:media, 0, :part, 0, :file)
    end

    test "preserves each repeated XML child as a complete object" do
      xml = <<~XML
        <MediaContainer>
          <Video title="Feature">
            <Media id="first" videoCodec="h264">
              <Part id="one" file="/media/part-one.mkv" />
              <Part id="two" file="/media/part-two.mkv" />
              <Part id="three" file="/media/part-three.mkv" />
            </Media>
            <Media id="second" videoCodec="hevc" />
          </Video>
        </MediaContainer>
      XML

      metadata = Client.new(token: "token").send(:media_container, xml)[:metadata].first

      assert_equal [ "first", "second" ], metadata[:media].map { |media| media[:id] }
      assert_equal [ "one", "two", "three" ], metadata[:media].first[:part].map { |part| part[:id] }
      assert_equal "/media/part-one.mkv", metadata.dig(:media, 0, :part, 0, :file)
    end

    test "parses singleton JSON collections without converting objects to key value pairs" do
      payload = {
        "MediaContainer" => {
          "User" => { "id" => "42", "Server" => { "id" => "share-one" } },
          "Server" => { "id" => "server-one" },
          "Invite" => { "id" => "invite-one", "Server" => { "name" => "Local Plex" } },
          "Metadata" => { "title" => "Feature", "Player" => { "title" => "Apple TV" } }
        }
      }
      client = Client.new(token: "token")
      body = JSON.generate(payload)

      container = client.send(:media_container, body)

      assert_equal "share-one", container.dig(:users, 0, :servers, 0, :id)
      assert_equal "server-one", container.dig(:servers, 0, :id)
      assert_equal "Local Plex", container.dig(:invites, 0, :servers, 0, :name)
      assert_equal "Feature", container.dig(:metadata, 0, :title)
      assert_equal "Apple TV", client.send(:session_document, body).first.dig(:player, :title)
    end

    test "keeps credentials out of request URLs while preserving history parameters" do
      captured = nil
      http = Object.new
      http.define_singleton_method(:request) do |request|
        captured = request
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response.define_singleton_method(:body) { "<MediaContainer />" }
        response
      end
      client = Client.new(token: "synthetic-secret", server_base_url: "https://plex.example", client_identifier: "client-one")

      with_http(http) { client.playback_history(account_id: "42", size: 20, offset: 40) }

      assert_equal "synthetic-secret", captured["X-Plex-Token"]
      assert_equal "client-one", captured["X-Plex-Client-Identifier"]
      assert_equal "GigaAdmin", captured["X-Plex-Product"]
      assert_not_includes captured.path, "synthetic-secret"
      assert_not_includes captured.path, "X-Plex-Token"
      query = URI.decode_www_form(URI(captured.path).query).to_h
      assert_equal "42", query["accountID"]
      assert_equal "20", query["X-Plex-Container-Size"]
      assert_equal "40", query["X-Plex-Container-Start"]
    end

    test "malformed responses do not expose response contents through errors or their causes" do
      client = Client.new(token: "token")
      malformed_xml = '<MediaContainer><User email="private@example.com"></MediaContainer>'
      malformed_json = '{"MediaContainer": private@example.com}'

      %i[media_container session_document server_document shared_server_document].each do |parser|
        error = assert_raises(Client::Error) { client.send(parser, malformed_xml) }
        assert_not_includes error.message, "private@example.com"
        assert_nil error.cause
      end
      %i[media_container session_document].each do |parser|
        error = assert_raises(Client::Error) { client.send(parser, malformed_json) }
        assert_not_includes error.message, "private@example.com"
        assert_nil error.cause
      end
    end

    test "escapes requested invite ids when canceling" do
      client = Client.new(token: "token")
      captured_path = nil
      captured_method = nil
      captured_params = nil
      client.define_singleton_method(:request) do |path, method:, params: {}|
        captured_path = path
        captured_method = method
        captured_params = params
        ""
      end

      client.cancel_requested_invite("pending@example.com", friend: false, home: false, server: true)

      assert_equal "/api/invites/requested/pending%40example.com", captured_path
      assert_equal :delete, captured_method
      assert_equal({ friend: 0, home: 0, server: 1 }, captured_params)
    end

    private

    def with_http(http)
      original = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) { |*_, **_, &block| block.call(http) }
      yield
    ensure
      Net::HTTP.define_singleton_method(:start, original)
    end
  end
end
