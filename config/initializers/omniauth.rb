require Rails.root.join("lib/admin_authentication")

# Reject a misspelled mode rather than silently enabling first-run setup.
AdminAuthentication.mode

Rails.application.config.middleware.use OmniAuth::Builder do
  if !AdminAuthentication.local? && AdminAuthentication.google_configured?
    provider :google_oauth2,
             ENV.fetch("GOOGLE_CLIENT_ID"),
             ENV.fetch("GOOGLE_CLIENT_SECRET"),
             {
               access_type: "online",
               prompt: "select_account",
               scope: "openid,email,profile"
             }
  end
end

OmniAuth.config.allowed_request_methods = [ :post ]
OmniAuth.config.silence_get_warning = true
