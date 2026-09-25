class RefreshRun < ApplicationRecord
  STATUSES = %w[queued running completed failed stale].freeze
  STALE_AFTER = 10.minutes

  validates :machine_identifier, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }
  scope :active, -> { where(status: %w[queued running]) }

  def self.latest_for(machine_identifier)
    where(machine_identifier: machine_identifier).latest_first.first
  end

  def self.active_for(machine_identifier)
    mark_stale_active!(machine_identifier)
    where(machine_identifier: machine_identifier).active.latest_first.first
  end

  def self.mark_stale_active!(machine_identifier = nil)
    scope = active.where(updated_at: ...STALE_AFTER.ago)
    scope = scope.where(machine_identifier: machine_identifier) if machine_identifier.present?

    # Keep eligibility in the UPDATE so a concurrent heartbeat or completion
    # cannot be overwritten after a stale row was loaded into memory.
    scope.update_all(
      status: "stale",
      finished_at: Time.current,
      updated_at: Time.current,
      error_message: "Refresh stopped reporting progress. It may have been interrupted by a deploy or worker restart.",
      last_message: "Refresh marked stale after #{STALE_AFTER.inspect} without progress"
    )
  end

  def active?
    status.in?(%w[queued running])
  end

  def stale?
    status == "stale"
  end

  def stale_active?
    active? && updated_at < STALE_AFTER.ago
  end

  def elapsed_seconds
    return unless started_at

    ((finished_at || Time.current) - started_at).round
  end

  def label
    status.humanize
  end
end
