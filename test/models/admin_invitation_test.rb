require "test_helper"

class AdminInvitationTest < ActiveSupport::TestCase
  setup do
    @previous_admin_users = ENV["ADMIN_USERS"]
    ENV.delete("ADMIN_USERS")
    @inviter = AdminUser.create!(email: "inviter@example.test", password: "correct-horse-battery-staple", super_admin: true)
  end

  teardown do
    ENV["ADMIN_USERS"] = @previous_admin_users
  end

  test "issues a normalized email invitation and stores only its token digest" do
    invitation, token = AdminInvitation.issue!(email: "  Friend@Example.test  ", invited_by: @inviter)

    assert_match(/\A[0-9a-f]{64}\z/, token)
    assert_equal "friend@example.test", invitation.email
    assert_equal Digest::SHA256.hexdigest(token), invitation.token_digest
    assert_not_includes invitation.attributes.values, token
    assert_in_delta 48.hours.from_now, invitation.expires_at, 1.second
    assert_equal invitation, AdminInvitation.find_available_by_token(token)
    assert_equal @inviter, invitation.invited_by
  end

  test "an invitation creates its bound account and can only be accepted once" do
    invitation, token = issue_invitation
    stale_invitation = AdminInvitation.find(invitation.id)

    assert_difference "AdminUser.count", 1 do
      admin = invitation.accept!(password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple")
      assert_equal invitation.email, admin.email
      assert admin.authenticate("correct-horse-battery-staple")
    end

    assert invitation.reload.accepted_at
    assert_nil AdminInvitation.find_available_by_token(token)
    assert_raises(AdminInvitation::InvalidInvitation) do
      stale_invitation.accept!(password: "another-valid-password", password_confirmation: "another-valid-password")
    end
  end

  test "invalid passwords do not consume invitations or create accounts" do
    invitation, token = issue_invitation

    assert_no_difference "AdminUser.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        invitation.accept!(password: "short", password_confirmation: "short")
      end
    end

    assert_nil invitation.reload.accepted_at
    assert_equal invitation, AdminInvitation.find_available_by_token(token)
  end

  test "expired and revoked invitations cannot be accepted including stale records" do
    invitation, token = issue_invitation
    stale_invitation = AdminInvitation.find(invitation.id)
    invitation.revoke!

    assert_not AdminInvitation.pending.exists?(invitation.id)
    assert_nil AdminInvitation.find_available_by_token(token)
    assert_raises(AdminInvitation::InvalidInvitation) do
      stale_invitation.accept!(password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple")
    end

    expiring_invitation, expiring_token = AdminInvitation.issue!(email: "later@example.test", invited_by: @inviter)
    travel_to(expiring_invitation.expires_at + 1.second) do
      assert_nil AdminInvitation.find_available_by_token(expiring_token)
      assert_raises(AdminInvitation::InvalidInvitation) do
        expiring_invitation.accept!(password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple")
      end
    end
  end

  test "existing administrators cannot be invited" do
    assert_no_difference "AdminInvitation.count" do
      error = assert_raises(ActiveRecord::RecordInvalid) do
        AdminInvitation.issue!(email: @inviter.email.upcase, invited_by: @inviter)
      end
      assert_includes error.record.errors[:email], "already has administrator access"
    end
  end

  test "ordinary administrators cannot issue invitations" do
    ordinary_admin = AdminUser.create!(email: "ordinary@example.test", password: "correct-horse-battery-staple")

    assert_no_difference "AdminInvitation.count" do
      assert_raises(AdminInvitation::NotAuthorized) do
        AdminInvitation.issue!(email: "friend@example.test", invited_by: ordinary_admin)
      end
    end
  end

  test "an invitation stops working when its sender loses super administrator authority" do
    configured_admin = AdminUser.create!(email: "configured@example.test", password: "correct-horse-battery-staple")
    ENV["ADMIN_USERS"] = configured_admin.email
    invitation, token = AdminInvitation.issue!(email: "friend@example.test", invited_by: configured_admin)
    ENV.delete("ADMIN_USERS")

    assert_nil AdminInvitation.find_available_by_token(token)
    assert_not AdminInvitation.pending.exists?(invitation.id)
    assert_raises(AdminInvitation::InvalidInvitation) do
      invitation.accept!(password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple")
    end
  end

  test "removing a former super administrator keeps their outstanding links invalid" do
    configured_admin = AdminUser.create!(email: "configured@example.test", password: "correct-horse-battery-staple")
    ENV["ADMIN_USERS"] = configured_admin.email
    invitation, token = AdminInvitation.issue!(email: "friend@example.test", invited_by: configured_admin)
    ENV.delete("ADMIN_USERS")
    configured_admin.destroy!

    assert_nil invitation.reload.invited_by_id
    assert_nil AdminInvitation.find_available_by_token(token)
    assert_not AdminInvitation.pending.exists?(invitation.id)
    assert_raises(AdminInvitation::InvalidInvitation) do
      invitation.accept!(password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple")
    end
  end

  test "malformed and unknown tokens do not identify invitations" do
    issue_invitation

    [ nil, [], { token: "anything" }, "not-a-token", "a" * 64 ].each do |token|
      assert_nil AdminInvitation.find_available_by_token(token)
    end
  end

  private

  def issue_invitation
    AdminInvitation.issue!(email: "friend@example.test", invited_by: @inviter)
  end
end
