require "test_helper"
require "io/console"
require "rake"

class AdminTasksTest < ActiveSupport::TestCase
  setup do
    @previous_auth_mode = ENV["GIGAADMIN_AUTH_MODE"]
    ENV["GIGAADMIN_AUTH_MODE"] = "local"
    @admin = AdminUser.create!(email: "recovery@example.test", password: "original-private-passphrase")
    Rails.application.load_tasks unless Rake::Task.task_defined?("admin:reset_password")
  end

  teardown do
    ENV["GIGAADMIN_AUTH_MODE"] = @previous_auth_mode
  end

  test "blank password recovery fails without changing credentials or claiming session revocation" do
    original_digest = @admin.password_digest
    original_version = @admin.session_version

    [ "", "   ", "\t" ].each do |password|
      output, error_output = capture_io do
        error = assert_raises(SystemExit) { reset_password([ password, password ]) }
        assert_equal 1, error.status
      end

      assert_includes error_output, "A nonblank new password is required."
      assert_not_includes output, "Password updated"
      assert_not_includes output, "sessions for this account are no longer valid"
      assert_equal original_digest, @admin.reload.password_digest
      assert_equal original_version, @admin.session_version
      assert @admin.authenticate("original-private-passphrase")
    end
  end

  test "successful recovery changes the password and invalidates previous sessions" do
    password = "replacement-private-passphrase"
    output, error_output = capture_io { reset_password([ password, password ]) }

    assert_equal "", error_output
    assert_equal 1, @admin.reload.session_version
    assert @admin.authenticate(password)
    assert_not @admin.authenticate("original-private-passphrase")
    assert_includes output, "Password updated. Existing sessions for this account are no longer valid."
    assert_not_includes output, password
  end

  private

  def reset_password(passwords)
    email = @admin.email
    console = Object.new
    console.define_singleton_method(:print) { |*| nil }
    console.define_singleton_method(:gets) { "#{email}\n" }
    console.define_singleton_method(:getpass) { |*| passwords.shift }
    original_console = IO.method(:console)
    IO.define_singleton_method(:console) { console }
    task = Rake::Task["admin:reset_password"]
    task.reenable
    task.invoke
  ensure
    IO.define_singleton_method(:console, original_console) if original_console
    task&.reenable
  end
end
