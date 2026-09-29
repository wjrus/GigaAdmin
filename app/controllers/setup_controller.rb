class SetupController < ApplicationController
  skip_before_action :require_admin!
  before_action :require_open_setup!
  rate_limit to: 10, within: 3.minutes, only: :create

  def new
    @admin_user = AdminUser.new
  end

  def create
    attributes = params.expect(admin_user: [ :email, :password, :password_confirmation ])
    @admin_user = AdminUser.bootstrap(attributes)
    start_local_session(@admin_user)
    redirect_to root_path, notice: "Administrator account created. Configure Plex and refresh your data from Maintenance."
  rescue AdminUser::SetupComplete
    redirect_to sign_in_path, alert: "Setup is already complete. Sign in or ask an administrator for an invitation."
  rescue ActiveRecord::RecordInvalid => error
    @admin_user = error.record
    render :new, status: :unprocessable_entity
  end

  private

  def require_open_setup!
    if !local_authentication?
      head :not_found
    elsif AdminUser.exists?
      redirect_to sign_in_path, alert: "Setup is already complete."
    end
  end
end
