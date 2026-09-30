# Legacy per-session details remain readable after the aggregate collector upgrade.
# New activity is stored in PlexActivitySample without user or device metadata.
class PlexNowPlayingSample < ApplicationRecord
  validates :machine_identifier, :sampled_at, presence: true

  scope :recent, -> { order(sampled_at: :desc, id: :desc) }
end
