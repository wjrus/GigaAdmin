module AdminAuthentication
  def self.mode
    configured = ENV.fetch("GIGAADMIN_AUTH_MODE", "auto")
    return configured if %w[google local].include?(configured)
    raise ArgumentError, "GIGAADMIN_AUTH_MODE must be auto, google, or local" unless configured == "auto"

    google_configured? ? "google" : "local"
  end

  def self.google_configured?
    ENV["GOOGLE_CLIENT_ID"].present? && ENV["GOOGLE_CLIENT_SECRET"].present?
  end

  def self.local?
    mode == "local"
  end
end
