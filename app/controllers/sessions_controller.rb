class SessionsController < ApplicationController
  skip_before_action :require_admin!
  rate_limit to: 10, within: 3.minutes, only: :authenticate

  def new
    if admin_signed_in?
      redirect_to root_path
    elsif local_authentication? && !AdminUser.exists?
      redirect_to setup_path
    end
  end

  def create
    return head :not_found if local_authentication?

    auth = request.env["omniauth.auth"]
    email = auth&.dig("info", "email").to_s.downcase

    unless auth.present? && admin_email_allowed?(email)
      reset_session
      redirect_to sign_in_path, alert: "That Google account is not allowed."
      return
    end

    reset_session
    session[:admin_email] = email
    session[:admin_name] = auth.dig("info", "name").presence || email

    redirect_to root_path, notice: "Signed in."
  end

  def authenticate
    return head :not_found unless local_authentication?

    credentials = params.expect(session: [ :email, :password ])
    password = credentials[:password].to_s
    admin = AdminUser.authenticate_by(email: credentials[:email].to_s.strip.downcase, password: password) if password.bytesize <= 72

    if admin
      start_local_session(admin)
      redirect_to root_path, notice: "Signed in."
    else
      reset_session
      flash.now[:alert] = "Email or password is incorrect."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to sign_in_path, notice: "Signed out."
  end

  def failure
    redirect_to sign_in_path, alert: "Google sign-in failed. Please try again."
  end
end
