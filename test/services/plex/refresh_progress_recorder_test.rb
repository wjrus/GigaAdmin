require "test_helper"

module Plex
  class RefreshProgressRecorderTest < ActiveSupport::TestCase
    test "records history page progress" do
      refresh_run = RefreshRun.create!(machine_identifier: "machine-one", status: "running")

      RefreshProgressRecorder.new(refresh_run).call(
        phase: "page",
        page: 2,
        rows: 1_000,
        matches: 12,
        remaining: 3,
        stop_reason: nil,
        streams: {}
      )

      refresh_run.reload
      assert_equal 2, refresh_run.history_pages_retrieved
      assert_equal 1_000, refresh_run.history_rows_retrieved
      assert_equal 12, refresh_run.history_users_matched
      assert_equal 3, refresh_run.history_users_remaining
      assert_equal "History page 2 retrieved: 1,000 rows, 12 users matched, 3 remaining", refresh_run.last_message
    end

    test "accumulates history rows across page progress events" do
      refresh_run = RefreshRun.create!(machine_identifier: "machine-one", status: "running")
      recorder = RefreshProgressRecorder.new(refresh_run)

      recorder.call(
        phase: "page",
        page: 1,
        rows: 1_000,
        matches: 5,
        remaining: 10,
        stop_reason: nil,
        streams: {}
      )
      recorder.call(
        phase: "page",
        page: 2,
        rows: 250,
        matches: 7,
        remaining: 8,
        stop_reason: "last page",
        streams: {}
      )

      refresh_run.reload
      assert_equal 2, refresh_run.history_pages_retrieved
      assert_equal 1_250, refresh_run.history_rows_retrieved
      assert_equal "History page 2 retrieved: 250 rows, 7 users matched, 8 remaining (last page)", refresh_run.last_message
    end

    test "reads the current row count once under lock when the record is stale" do
      refresh_run = RefreshRun.create!(machine_identifier: "machine-one", status: "running")
      RefreshRun.find(refresh_run.id).update!(history_rows_retrieved: 1_000)
      reads = []
      subscriber = lambda do |event|
        sql = event.payload[:sql]
        reads << sql if sql.match?(/SELECT.*FROM "refresh_runs"/)
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        RefreshProgressRecorder.new(refresh_run).call(
          phase: "page", page: 2, rows: 250, matches: 7, remaining: 0, stop_reason: "last page"
        )
      end

      assert_equal 1_250, refresh_run.reload.history_rows_retrieved
      assert_equal 1, reads.size
      assert_includes reads.first, "FOR UPDATE"
    end
  end
end
