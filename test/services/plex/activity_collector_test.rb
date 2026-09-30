require "test_helper"

class Plex::ActivityCollectorTest < ActiveSupport::TestCase
  setup do
    @previous_env = ENV.to_h.slice("PLEX_MACHINE_IDENTIFIER", "PLEX_SERVER_BASE_URL", "PLEX_TOKEN")
    ENV["PLEX_MACHINE_IDENTIFIER"] = "collector-machine"
    ENV["PLEX_SERVER_BASE_URL"] = "http://plex.example.test"
    ENV["PLEX_TOKEN"] = "synthetic-test-token"
  end

  teardown do
    %w[PLEX_MACHINE_IDENTIFIER PLEX_SERVER_BASE_URL PLEX_TOKEN].each { |key| ENV[key] = @previous_env[key] }
  end

  test "successful empty playback results are stored as idle observations" do
    with_client do
      assert_difference "PlexActivitySample.count", 1 do
        sample = Plex::ActivityCollector.call
        assert_equal "collector-machine", sample.machine_identifier
        assert_equal 0, sample.total_sessions
      end
    end
  end

  test "API failures leave a gap instead of recording zero" do
    with_client(-> { raise Plex::Client::Error, "Synthetic failure" }) do
      assert_no_difference "PlexActivitySample.count" do
        assert_raises(Plex::Client::Error) { Plex::ActivityCollector.call }
      end
    end
  end

  test "missing configuration cannot create an idle observation or call the client" do
    original = Plex::Client.method(:from_env)
    calls = 0
    Plex::Client.define_singleton_method(:from_env) { calls += 1; raise "Client should not be reached" }

    %w[PLEX_MACHINE_IDENTIFIER PLEX_SERVER_BASE_URL].each do |key|
      value = ENV.delete(key)
      assert_no_difference "PlexActivitySample.count" do
        assert_raises(Plex::ConfigurationError) { Plex::ActivityCollector.call }
      end
      ENV[key] = value
    end
    assert_equal 0, calls
  ensure
    Plex::Client.define_singleton_method(:from_env, original)
  end

  private

  def with_client(sessions = -> { [] })
    original = Plex::Client.method(:from_env)
    client = Object.new
    client.define_singleton_method(:playback_sessions, sessions)
    Plex::Client.define_singleton_method(:from_env) { client }
    yield
  ensure
    Plex::Client.define_singleton_method(:from_env, original)
  end
end
