require "test_helper"
require "rake"

class PlexRakeTest < ActiveSupport::TestCase
  test "backfill raises after exhausted retries instead of returning success" do
    original = ENV.to_h.slice("PLEX_MACHINE_IDENTIFIER", "PLEX_HISTORY_RETRIES")
    ENV["PLEX_MACHINE_IDENTIFIER"] = "synthetic-backfill"
    ENV["PLEX_HISTORY_RETRIES"] = "0"
    client = Object.new
    client.define_singleton_method(:playback_history) { |**_| raise Plex::Client::Error, "Synthetic timeout" }
    original_from_env = Plex::Client.method(:from_env)
    Plex::Client.define_singleton_method(:from_env) { client }
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "plex:refresh" }
    task = Rake::Task["plex:backfill_history"]
    task.reenable

    capture_io do
      assert_raises(Plex::Client::Error) { task.invoke }
    end
    assert_equal "failed", RefreshRun.latest_for("synthetic-backfill").status
  ensure
    %w[PLEX_MACHINE_IDENTIFIER PLEX_HISTORY_RETRIES].each { |key| ENV[key] = original[key] }
    Plex::Client.define_singleton_method(:from_env, original_from_env)
    task&.reenable
  end

  test "resumed backfill applies max pages to pages scanned rather than the absolute page number" do
    settings = {
      "PLEX_MACHINE_IDENTIFIER" => "synthetic-resumed-backfill",
      "PLEX_HISTORY_RETRIES" => "0",
      "PLEX_HISTORY_START_PAGE" => "3",
      "PLEX_HISTORY_MAX_PAGES" => "2",
      "PLEX_HISTORY_PAGE_SIZE" => "2",
      "PLEX_HISTORY_DAYS" => "all"
    }
    original = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    calls = []
    client = Object.new
    client.define_singleton_method(:playback_history) do |size:, offset:|
      calls << [ size, offset ]
      Array.new(size) { |index| { account_id: "42", rating_key: (offset + index).to_s, viewed_at: Time.current.to_i } }
    end
    original_from_env = Plex::Client.method(:from_env)
    Plex::Client.define_singleton_method(:from_env) { client }
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "plex:backfill_history" }
    task = Rake::Task["plex:backfill_history"]
    task.reenable

    output, = capture_io do
      assert_difference -> { PlexStreamEvent.where(machine_identifier: settings["PLEX_MACHINE_IDENTIFIER"]).count }, 4 do
        task.invoke
      end
    end

    assert_equal [ [ 2, 4 ], [ 2, 6 ] ], calls
    assert_match "Pages scanned: 2", output
    run = RefreshRun.latest_for(settings["PLEX_MACHINE_IDENTIFIER"])
    assert_equal "completed", run.status
    assert_equal 4, run.history_rows_retrieved
    assert_equal 4, run.history_pages_retrieved
  ensure
    settings&.each_key { |key| ENV[key] = original[key] }
    Plex::Client.define_singleton_method(:from_env, original_from_env) if original_from_env
    task&.reenable
  end

  test "plex refresh task is defined" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "plex:refresh" }

    assert Rake::Task.task_defined?("plex:refresh")
  end

  test "plex history backfill task is defined" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "plex:backfill_history" }

    assert Rake::Task.task_defined?("plex:backfill_history")
  end

  test "plex now playing sample task is defined" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "plex:sample_now_playing" }

    assert Rake::Task.task_defined?("plex:sample_now_playing")
  end
end
