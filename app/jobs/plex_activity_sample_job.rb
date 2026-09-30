class PlexActivitySampleJob < ApplicationJob
  queue_as :default
  queue_with_priority(-10)
  limits_concurrency to: 1, key: "plex-activity", duration: 2.minutes, on_conflict: :discard

  def perform
    return unless PlexActivitySample.enabled?
    return if ENV["PLEX_MACHINE_IDENTIFIER"].blank? || ENV["PLEX_SERVER_BASE_URL"].blank? || ENV["PLEX_TOKEN"].blank?
    return if enqueued_at && enqueued_at < 2.minutes.ago

    Plex::ActivityCollector.call
  rescue Plex::ConfigurationError, Plex::Client::Error => error
    # The next poll retries. Do not enqueue a backlog or log tokens/response bodies.
    Rails.logger.warn("[plex.activity] collection failed (#{error.class}); no sample recorded")
  end
end
