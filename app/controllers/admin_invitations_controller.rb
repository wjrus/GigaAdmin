class AdminInvitationsController < ApplicationController
  skip_before_action :require_admin!, only: %i[show accept]
  before_action :protect_invitation_response
  before_action :require_local_invitation_mode!
  before_action :require_local_inviting_admin!, only: %i[create destroy]

  rate_limit to: 10, within: 1.minute, only: %i[create accept]

  def create
    current_password = params[:current_password].to_s
    unless current_password.bytesize <= 72 && current_local_admin.authenticate(current_password)
      redirect_to admin_users_path, alert: "Confirm your current password to invite an administrator.", status: :see_other
      return
    end

    @invitation, token = AdminInvitation.issue!(email: params.require(:admin_invitation).permit(:email)[:email], invited_by: current_local_admin)
    @invitation_url = accept_admin_invitation_url(token: token)
    render :created, status: :created
  rescue ActiveRecord::RecordInvalid => error
    redirect_to admin_users_path, alert: error.record.errors.full_messages.to_sentence, status: :see_other
  rescue AdminInvitation::NotAuthorized
    head :forbidden
  end

  def destroy
    AdminInvitation.find(params[:id]).revoke!
    redirect_to admin_users_path, notice: "Administrator invitation revoked.", status: :see_other
  end

  def show
    return unless load_invitation

    @admin_user = AdminUser.new(email: @invitation.email)
  end

  def accept
    return unless load_invitation

    credentials = params.require(:admin_user).permit(:password, :password_confirmation)
    admin = @invitation.accept!(password: credentials[:password], password_confirmation: credentials[:password_confirmation])
    start_local_session(admin)
    redirect_to root_path, notice: "Your administrator account is ready.", status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    @admin_user = error.record
    render :show, status: :unprocessable_entity
  rescue AdminInvitation::InvalidInvitation
    render :unavailable, status: :gone
  end

  private

  def protect_invitation_response
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end

  def require_local_invitation_mode!
    head :not_found unless local_authentication?
  end

  def require_local_inviting_admin!
    head :forbidden unless current_super_admin?
  end

  def load_invitation
    @token = params[:token]
    @invitation = AdminInvitation.find_available_by_token(@token)
    return true if @invitation

    render :unavailable, status: :gone
    false
  end
end
