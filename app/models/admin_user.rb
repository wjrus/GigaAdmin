class AdminUser < ApplicationRecord
  class SetupComplete < StandardError; end

  SETUP_LOCK_ID = 4_746_941_416_468_109

  has_secure_password

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true,
    length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, if: -> { password.present? }

  before_update :revoke_existing_sessions, if: :will_save_change_to_password_digest?
  before_destroy :retain_last_administrator

  def super_admin?
    self[:super_admin] == true || self.class.configured_super_admin_emails.include?(email)
  end

  def self.configured_super_admin_emails
    ENV.fetch("ADMIN_USERS", "")
      .split(",").map { |email| email.strip.downcase }.reject(&:blank?)
  end

  def self.super_administrators
    emails = configured_super_admin_emails
    where(super_admin: true).or(where(email: emails))
  end

  def self.bootstrap(attributes)
    transaction do
      acquire_setup_lock
      raise SetupComplete, "An administrator has already completed setup." if uncached { exists? }

      admin = new(attributes)
      admin.super_admin = true
      if configured_super_admin_emails.any? && !configured_super_admin_emails.include?(admin.email)
        admin.errors.add(:email, "is not permitted for initial setup")
        raise ActiveRecord::RecordInvalid, admin
      end
      admin.save!
      admin
    end
  end

  def self.acquire_setup_lock
    connection.execute("SELECT pg_advisory_xact_lock(#{SETUP_LOCK_ID})")
  end
  private_class_method :acquire_setup_lock

  private

  def revoke_existing_sessions
    # Lock and read the current version so concurrent password changes each
    # invalidate the sessions issued after the preceding change.
    self.session_version = self.class.where(id: id).lock.pick(:session_version) + 1
  end

  def retain_last_administrator
    self.class.send(:acquire_setup_lock)
    if self.class.uncached { self.class.lock.find_by(id: id)&.super_admin? }
      errors.add(:base, "The super administrator cannot be removed.")
      throw :abort
    end
    return if self.class.uncached { self.class.where.not(id: id).exists? }

    errors.add(:base, "The last administrator cannot be removed.")
    throw :abort
  end
end
