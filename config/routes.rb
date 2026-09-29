Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  match "/auth/google_oauth2/callback", to: "sessions#create", via: [ :get, :post ]
  match "/auth/failure", to: "sessions#failure", via: [ :get, :post ]
  get "/sign_in", to: "sessions#new", as: :sign_in
  post "/sign_in", to: "sessions#authenticate", as: :local_sign_in
  delete "/sign_out", to: "sessions#destroy", as: :sign_out
  get "/setup", to: "setup#new", as: :setup
  post "/setup", to: "setup#create"
  get "/admin/users", to: "admin_users#index", as: :admin_users
  patch "/admin/password", to: "admin_users#update_password", as: :admin_password
  delete "/admin/users/:id", to: "admin_users#destroy", as: :admin_user
  post "/admin/invitations", to: "admin_invitations#create", as: :admin_invitations
  delete "/admin/invitations/:id", to: "admin_invitations#destroy", as: :admin_invitation
  get "/admin/accept_invitation", to: "admin_invitations#show", as: :accept_admin_invitation
  post "/admin/accept_invitation", to: "admin_invitations#accept"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "shares#index"
  get "now", to: "now_playing#index", as: :now_playing
  get "plex_cover", to: "plex_covers#show", as: :plex_cover
  get "log", to: "share_audit_logs#index", as: :share_audit_logs
  get "stats", to: "stats#index", as: :stats
  get "libraries/:library_title", to: "libraries#show", as: :library
  get "status", to: "status#index", as: :status
  get "maintenance", to: "maintenance#index", as: :maintenance
  get "maintenance/refresh", to: "maintenance#refresh", as: :maintenance_refresh
  post "maintenance/sample_now_playing", to: "maintenance#sample_now_playing", as: :maintenance_sample_now_playing
  post "maintenance/prune_now_playing_samples", to: "maintenance#prune_now_playing_samples", as: :maintenance_prune_now_playing_samples
  get "suppressed", to: "suppressed_users#index", as: :suppressed_users
  get "users", to: "users#index", as: :users
  get "users/:plex_user_id.:format", to: "users#show", constraints: { plex_user_id: /[^\/]+/, format: /csv/ }
  get "users/:plex_user_id", to: "users#show", as: :user, constraints: { plex_user_id: /[^\/]+/ }
  patch "users/:plex_user_id/note", to: "users#update_note", as: :user_note, constraints: { plex_user_id: /[^\/]+/ }
  patch "users/:plex_user_id/suppression", to: "users#update_suppression", as: :user_suppression, constraints: { plex_user_id: /[^\/]+/ }
  post "refresh", to: "shares#refresh", as: :refresh_shares
  post "shares", to: "shares#create"
  post "shares/bulk", to: "shares#bulk_update", as: :bulk_shares
  patch "shares/:share_id", to: "shares#update", as: :share
  delete "shares/:share_id", to: "shares#destroy"
  delete "invites/:invite_id", to: "shares#destroy_invite", as: :pending_invite, constraints: { invite_id: /[^\/]+/ }
end
