namespace :admin do
  desc "Reset a local administrator password using private terminal prompts"
  task reset_password: :environment do
    require "io/console"
    abort "Local authentication is not enabled." unless AdminAuthentication.local?
    console = IO.console
    abort "Run this task in an interactive terminal; passwords are never accepted as command arguments." unless console

    console.print "Administrator email: "
    email = console.gets&.strip&.downcase
    admin = AdminUser.find_by(email: email)
    abort "No administrator with that email. This task does not create accounts." unless admin

    password = console.getpass("New password (at least 12 characters): ")
    abort "A nonblank new password is required." if password.blank?

    confirmation = console.getpass("Confirm password: ")
    admin.update!(password: password, password_confirmation: confirmation)
    puts "Password updated. Existing sessions for this account are no longer valid."
  rescue ActiveRecord::RecordInvalid => error
    abort error.record.errors.full_messages.to_sentence
  end
end
