class ApplicationController < ActionController::Base
  before_action :require_admin!
  helper_method :admin_signed_in?, :current_admin_email, :local_authentication?, :current_local_admin, :current_super_admin?

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def require_admin!
    return if admin_signed_in?

    reset_session
    redirect_to(local_authentication? && !AdminUser.exists? ? setup_path : sign_in_path)
  end

  def admin_signed_in?
    current_admin_email.present?
  end

  def current_admin_email
    return current_local_admin&.email if local_authentication?

    email = session[:admin_email].presence
    email if email && admin_email_allowed?(email)
  end

  def local_authentication?
    AdminAuthentication.local?
  end

  def current_local_admin
    return unless local_authentication?
    return @current_local_admin if defined?(@current_local_admin)

    admin = AdminUser.find_by(id: session[:local_admin_id]) if session[:local_admin_id]
    @current_local_admin = admin if admin && admin.session_version == session[:local_admin_version]
  end

  def start_local_session(admin)
    reset_session
    session[:local_admin_id] = admin.id
    session[:local_admin_version] = admin.session_version
    @current_local_admin = admin
  end

  def current_super_admin?
    return current_local_admin&.super_admin? || false if local_authentication?

    admin_signed_in?
  end

  def admin_email_allowed?(email)
    allowed_admin_emails.include?(email.to_s.downcase)
  end

  def allowed_admin_emails
    (ENV["ADMIN_USERS"].presence || ENV["ADMIN_USER"].presence || "")
      .split(",")
      .map { |email| email.strip.downcase }
      .reject(&:blank?)
  end
end
