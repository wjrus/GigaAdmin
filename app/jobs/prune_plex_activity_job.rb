class PrunePlexActivityJob < ApplicationJob
  queue_as :default

  def perform
    PlexActivitySample.prune!
  end
end
