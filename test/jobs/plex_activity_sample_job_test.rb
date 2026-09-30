require "test_helper"

class PlexActivitySampleJobTest < ActiveSupport::TestCase
  setup do
    @keys = %w[PLEX_ACTIVITY_ENABLED PLEX_MACHINE_IDENTIFIER PLEX_SERVER_BASE_URL PLEX_TOKEN]
    @previous_env = ENV.to_h.slice(*@keys)
    ENV["PLEX_ACTIVITY_ENABLED"] = "true"
    ENV["PLEX_MACHINE_IDENTIFIER"] = "job-machine"
    ENV["PLEX_SERVER_BASE_URL"] = "http://plex.example.test"
    ENV["PLEX_TOKEN"] = "synthetic-token"
  end

  teardown do
    @keys.each { |key| ENV[key] = @previous_env[key] }
  end

  test "configured fresh jobs collect while disabled incomplete and stale jobs do not" do
    calls = 0
    with_collector(-> { calls += 1 }) do
      PlexActivitySampleJob.new.perform
      assert_equal 1, calls

      ENV["PLEX_ACTIVITY_ENABLED"] = "false"
      PlexActivitySampleJob.new.perform
      ENV["PLEX_ACTIVITY_ENABLED"] = "true"
      %w[PLEX_MACHINE_IDENTIFIER PLEX_SERVER_BASE_URL PLEX_TOKEN].each do |key|
        value = ENV.delete(key)
        PlexActivitySampleJob.new.perform
        ENV[key] = value
      end
      late = PlexActivitySampleJob.new
      late.enqueued_at = 3.minutes.ago
      late.perform
      assert_equal 1, calls
    end
  end

  test "collection errors leave a gap without leaking error contents or scheduling retries" do
    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    [ Plex::Client::Error, Plex::ConfigurationError ].each do |error_class|
      with_collector(-> { raise error_class, "synthetic-secret private@example.test" }) do
        assert_no_difference "PlexActivitySample.count" do
          PlexActivitySampleJob.new.perform
        end
      end
    end

    assert_includes log.string, "no sample recorded"
    assert_not_includes log.string, "synthetic-secret"
    assert_not_includes log.string, "private@example.test"
  ensure
    Rails.logger = original_logger
  end

  private

  def with_collector(implementation)
    original = Plex::ActivityCollector.method(:call)
    Plex::ActivityCollector.define_singleton_method(:call, implementation)
    yield
  ensure
    Plex::ActivityCollector.define_singleton_method(:call, original)
  end
end
