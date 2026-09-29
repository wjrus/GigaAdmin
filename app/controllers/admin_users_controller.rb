class AdminUsersController < ApplicationController
  before_action :require_local_authentication!
  before_action :require_super_admin!, only: :destroy
  rate_limit to: 10, within: 3.minutes, only: [ :update_password, :destroy ]

  def index
    @admin_users = current_super_admin? ? AdminUser.order(:email) : AdminUser.where(id: current_local_admin.id)
    @admin_invitations = current_super_admin? ? AdminInvitation.pending.order(created_at: :desc) : AdminInvitation.none
  end

  def update_password
    return unless confirm_password!

    attributes = params.expect(admin_user: [ :password, :password_confirmation ])
    if attributes[:password].blank?
      redirect_to admin_users_path, alert: "A new password is required."
      return
    end

    if current_local_admin.update(attributes)
      start_local_session(current_local_admin)
      redirect_to admin_users_path, notice: "Password changed. Other sessions for this account have been signed out."
    else
      redirect_to admin_users_path, alert: current_local_admin.errors.full_messages.to_sentence
    end
  end

  def destroy
    return unless confirm_password!

    admin = AdminUser.find(params[:id])
    if admin.destroy
      if admin == current_local_admin
        reset_session
        redirect_to sign_in_path, notice: "Your administrator account was removed."
      else
        redirect_to admin_users_path, notice: "Administrator removed. Their sessions are no longer valid."
      end
    else
      redirect_to admin_users_path, alert: admin.errors.full_messages.to_sentence
    end
  end

  private

  def require_local_authentication!
    head :not_found unless local_authentication?
  end

  def require_super_admin!
    head :forbidden unless current_super_admin?
  end

  def confirm_password!
    password = params[:current_password].to_s
    return true if password.bytesize <= 72 && current_local_admin.authenticate(password)

    redirect_to admin_users_path, alert: "Your current password is incorrect."
    false
  end
end
