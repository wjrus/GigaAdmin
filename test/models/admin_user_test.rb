require "test_helper"

class AdminUserTest < ActiveSupport::TestCase
  setup do
    @previous_admin_configuration = %w[ADMIN_USER ADMIN_USERS].to_h { |key| [ key, ENV.delete(key) ] }
  end

  teardown do
    @previous_admin_configuration.each do |key, value|
      value ? ENV[key] = value : ENV.delete(key)
    end
  end

  test "normalizes emails and stores an authenticated password hash" do
    admin = AdminUser.create!(email: " Owner@Example.COM ", password: "correct horse battery")

    assert_equal "owner@example.com", admin.email
    assert_equal admin, AdminUser.find_by(email: " OWNER@example.com ")
    assert_not_equal "correct horse battery", admin.password_digest
    assert_equal admin, admin.authenticate("correct horse battery")
    assert_not admin.authenticate("incorrect password")
    assert_equal 0, admin.session_version
    assert_not admin.super_admin?
  end

  test "requires a valid unique email" do
    AdminUser.create!(email: "owner@example.com", password: "correct horse battery")
    duplicate = AdminUser.new(email: " OWNER@EXAMPLE.COM ", password: "another secure password")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"

    [ nil, "", "owner", "owner@example.com\nsecond@example.com", "a" * 243 + "@example.com" ].each do |email|
      invalid = AdminUser.new(email: email, password: "correct horse battery")
      assert_not invalid.valid?, "Accepted invalid email #{email.inspect}"
      assert invalid.errors[:email].any?
    end
  end

  test "requires a password of at least twelve characters and at most seventy two bytes" do
    [ nil, "", "a" * 11, "a" * 73, "😀" * 19 ].each do |password|
      admin = AdminUser.new(email: "owner@example.com", password: password)
      assert_not admin.valid?, "Accepted invalid password length"
      assert admin.errors[:password].any?
    end

    assert AdminUser.new(email: "owner@example.com", password: "a" * 12).valid?
    assert AdminUser.new(email: "owner@example.com", password: "a" * 72).valid?
  end

  test "validates password confirmation when provided" do
    admin = AdminUser.new(email: "owner@example.com", password: "correct horse battery", password_confirmation: "different password")

    assert_not admin.valid?
    assert admin.errors[:password_confirmation].any?
  end

  test "bootstrap creates the first super administrator and closes registration" do
    admin = AdminUser.bootstrap(email: "first@example.com", password: "correct horse battery")

    assert admin.persisted?
    assert admin.super_admin?
    assert admin.reload[:super_admin]
    assert_raises(AdminUser::SetupComplete) do
      AdminUser.bootstrap(email: "second@example.com", password: "correct horse battery")
    end
    assert_equal 1, AdminUser.count
  end

  test "bootstrap requires an allowlisted super administrator email without disclosing it" do
    ENV["ADMIN_USERS"] = " Owner@Example.COM , another@example.com "

    error = assert_raises(ActiveRecord::RecordInvalid) do
      AdminUser.bootstrap(email: "someone@example.com", password: "correct horse battery")
    end
    assert_includes error.record.errors[:email], "is not permitted for initial setup"
    assert_not_includes error.message, "owner@example.com"
    assert_equal 0, AdminUser.count

    admin = AdminUser.bootstrap(email: " OWNER@example.com ", password: "correct horse battery")
    assert admin.super_admin?
  end

  test "configured super administrator list adds to the permanent first administrator role" do
    original = AdminUser.bootstrap(email: "first@example.com", password: "correct horse battery")
    replacement = AdminUser.create!(email: "replacement@example.com", password: "correct horse battery")
    ENV["ADMIN_USERS"] = " Replacement@Example.COM "

    assert original.super_admin?
    assert replacement.super_admin?
    assert_not replacement[:super_admin]
    assert_not original.destroy
    assert_not replacement.destroy
    assert_includes replacement.errors[:base], "The super administrator cannot be removed."

    ENV.delete("ADMIN_USERS")
    assert original.super_admin?
    assert_not replacement.super_admin?
    assert replacement.destroy
  end

  test "super administrator query combines the first account with only the ADMIN_USERS list" do
    original = AdminUser.bootstrap(email: "first@example.com", password: "correct horse battery")
    replacement = AdminUser.create!(email: "replacement@example.com", password: "correct horse battery")
    assert_equal [ original ], AdminUser.super_administrators.to_a

    ENV["ADMIN_USER"] = " First@Example.com, replacement@example.com "
    assert original.super_admin?
    assert_not replacement.super_admin?
    assert_equal [ original ], AdminUser.super_administrators.to_a

    ENV["ADMIN_USERS"] = " REPLACEMENT@example.com "
    assert original.super_admin?
    assert replacement.super_admin?
    assert_equal [ original, replacement ].map(&:id).sort, AdminUser.super_administrators.pluck(:id).sort
  end

  test "invalid first administrator leaves setup available" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AdminUser.bootstrap(email: "first@example.com", password: "short")
    end

    assert_equal 0, AdminUser.count
    assert AdminUser.bootstrap(email: "first@example.com", password: "correct horse battery").persisted?
  end

  test "bootstrap holds the setup lock until the account transaction commits" do
    with_competing_connection do |competitor|
      assert_equal "t", competitor.exec("SELECT pg_try_advisory_xact_lock(#{AdminUser::SETUP_LOCK_ID})").getvalue(0, 0)

      AdminUser.bootstrap(email: "first@example.com", password: "correct horse battery")

      assert_equal "f", competitor.exec("SELECT pg_try_advisory_xact_lock(#{AdminUser::SETUP_LOCK_ID})").getvalue(0, 0)
    end
  end

  test "changing the password advances the session version but editing email does not" do
    admin = AdminUser.create!(email: "owner@example.com", password: "correct horse battery")
    admin.update!(email: "new-owner@example.com")
    assert_equal 0, admin.reload.session_version

    admin.update!(password: "updated secure password")
    assert_equal 1, admin.reload.session_version
    assert_not admin.authenticate("correct horse battery")
    assert_equal admin, admin.authenticate("updated secure password")
  end

  test "password changes from a stale instance still advance the current session version" do
    admin = AdminUser.create!(email: "owner@example.com", password: "correct horse battery")
    stale_admin = AdminUser.find(admin.id)

    admin.update!(password: "first updated password")
    stale_admin.update!(password: "second updated password")

    assert_equal 2, admin.reload.session_version
    assert_equal admin, admin.authenticate("second updated password")
  end

  test "invalid password change does not revoke sessions" do
    admin = AdminUser.create!(email: "owner@example.com", password: "correct horse battery")

    assert_not admin.update(password: "short")
    assert_equal 0, admin.reload.session_version
    assert_equal admin, admin.authenticate("correct horse battery")
  end

  test "the last administrator cannot be removed or reopen setup" do
    admin = AdminUser.create!(email: "owner@example.com", password: "correct horse battery")

    assert_not admin.destroy
    assert_includes admin.errors[:base], "The last administrator cannot be removed."
    assert AdminUser.exists?(admin.id)
    assert_raises(AdminUser::SetupComplete) do
      AdminUser.bootstrap(email: "replacement@example.com", password: "correct horse battery")
    end
  end

  test "the first super administrator cannot be removed even with other administrators" do
    owner = AdminUser.bootstrap(email: "owner@example.com", password: "correct horse battery")
    AdminUser.create!(email: "helper@example.com", password: "correct horse battery")

    assert_not owner.destroy
    assert_includes owner.errors[:base], "The super administrator cannot be removed."
    assert AdminUser.exists?(owner.id)
  end

  test "destruction checks the persisted super administrator role" do
    owner = AdminUser.bootstrap(email: "owner@example.com", password: "correct horse battery")
    AdminUser.create!(email: "helper@example.com", password: "correct horse battery")
    owner.super_admin = false

    assert_not owner.destroy
    assert AdminUser.find(owner.id).super_admin?
  end

  test "an administrator can be removed while another remains" do
    first = AdminUser.create!(email: "first@example.com", password: "correct horse battery")
    second = AdminUser.create!(email: "second@example.com", password: "correct horse battery")

    assert first.destroy
    assert_not AdminUser.exists?(first.id)
    assert_not second.destroy
    assert AdminUser.exists?(second.id)
  end

  test "removal holds the same lock so another removal cannot empty the table" do
    first = AdminUser.create!(email: "first@example.com", password: "correct horse battery")
    AdminUser.create!(email: "second@example.com", password: "correct horse battery")

    with_competing_connection do |competitor|
      assert_equal "t", competitor.exec("SELECT pg_try_advisory_xact_lock(#{AdminUser::SETUP_LOCK_ID})").getvalue(0, 0)

      assert first.destroy

      assert_equal "f", competitor.exec("SELECT pg_try_advisory_xact_lock(#{AdminUser::SETUP_LOCK_ID})").getvalue(0, 0)
    end
  end

  private

  def with_competing_connection
    config = AdminUser.connection_db_config.configuration_hash
    connection = PG.connect(dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username], password: config[:password])
    yield connection
  ensure
    connection&.close
  end
end
