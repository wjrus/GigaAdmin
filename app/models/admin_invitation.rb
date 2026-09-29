require "digest"
require "securerandom"

class AdminInvitation < ApplicationRecord
  class InvalidInvitation < StandardError; end
  class NotAuthorized < StandardError; end

  EXPIRATION = 48.hours

  belongs_to :invited_by, class_name: "AdminUser", optional: true

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :invited_by, presence: true, on: :create
  validates :token_digest, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :expires_at, presence: true
  validate :email_is_not_an_admin, on: :create

  scope :pending, -> {
    where(accepted_at: nil, revoked_at: nil, invited_by_id: AdminUser.super_administrators.select(:id))
      .where("expires_at > ?", Time.current)
  }

  def self.issue!(email:, invited_by:)
    raise NotAuthorized unless invited_by&.super_admin?

    token = SecureRandom.hex(32)
    invitation = create!(email: email, invited_by: invited_by,
                         token_digest: Digest::SHA256.hexdigest(token), expires_at: EXPIRATION.from_now)
    [ invitation, token ]
  end

  def self.find_available_by_token(token)
    return unless token.is_a?(String) && token.match?(/\A[0-9a-f]{64}\z/)

    pending.find_by(token_digest: Digest::SHA256.hexdigest(token))
  end

  def pending?
    accepted_at.nil? && revoked_at.nil? && expires_at > Time.current && AdminUser.find_by(id: invited_by_id)&.super_admin?
  end

  def accept!(password:, password_confirmation:)
    with_lock do
      raise InvalidInvitation unless pending?

      admin = AdminUser.create!(email: email, password: password, password_confirmation: password_confirmation)
      update!(accepted_at: Time.current)
      admin
    end
  rescue ActiveRecord::RecordNotUnique
    raise InvalidInvitation
  end

  def revoke!
    with_lock { update!(revoked_at: Time.current) if pending? }
  end

  private

  def email_is_not_an_admin
    errors.add(:email, "already has administrator access") if AdminUser.exists?(email: email)
  end
end
