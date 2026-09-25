require "test_helper"

class RefreshRunTest < ActiveSupport::TestCase
  test "finds latest and active runs for a machine" do
    completed = RefreshRun.create!(machine_identifier: "machine-one", status: "completed", finished_at: 1.hour.ago)
    queued = RefreshRun.create!(machine_identifier: "machine-one", status: "queued")
    RefreshRun.create!(machine_identifier: "machine-two", status: "running")

    assert_equal queued, RefreshRun.latest_for("machine-one")
    assert_equal queued, RefreshRun.active_for("machine-one")
    assert_not completed.active?
  end

  test "marks abandoned active runs stale" do
    running = RefreshRun.create!(machine_identifier: "machine-one", status: "running", updated_at: 20.minutes.ago)

    assert_nil RefreshRun.active_for("machine-one")

    running.reload
    assert_equal "stale", running.status
    assert running.finished_at.present?
    assert_match "stopped reporting progress", running.error_message
  end

  test "stale marking is one conditional update scoped to abandoned active runs" do
    travel_to Time.current.change(usec: 0) do
      stale = %w[queued running].map do |status|
        RefreshRun.create!(machine_identifier: "machine-one", status: status, updated_at: 20.minutes.ago)
      end
      renewed = RefreshRun.create!(machine_identifier: "machine-one", status: "running", updated_at: 20.minutes.ago)
      renewed.touch
      completed = RefreshRun.create!(machine_identifier: "machine-one", status: "completed", updated_at: 20.minutes.ago)
      other_machine = RefreshRun.create!(machine_identifier: "machine-two", status: "running", updated_at: 20.minutes.ago)
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].include?("refresh_runs") }

      changed = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        RefreshRun.mark_stale_active!("machine-one")
      end

      assert_equal 2, changed
      assert_equal 1, queries.size
      assert_match(/\AUPDATE /, queries.first)
      stale.each do |run|
        assert_equal "stale", run.reload.status
        assert_equal Time.current, run.finished_at
        assert_equal Time.current, run.updated_at
      end
      assert_equal "running", renewed.reload.status
      assert_equal "completed", completed.reload.status
      assert_equal "running", other_machine.reload.status
    end
  end
end
