require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class SetupScriptTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("gigaadmin-setup-")
    FileUtils.mkdir_p(File.join(@directory, "scripts"))
    FileUtils.mkdir_p(File.join(@directory, "bin"))
    FileUtils.cp(Rails.root.join("scripts/setup"), File.join(@directory, "scripts/setup"))
    %w[.env.docker.example .env.production.example .env.postgres.example].each do |template|
      FileUtils.cp(Rails.root.join(template), File.join(@directory, template))
    end
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "generates a private matching configuration from another working directory" do
    output, status = run_setup

    assert status.success?, output
    application = environment_file(".env.production")
    database = environment_file(".env.postgres")
    compose = environment_file(".env")
    assert_match(/\A[0-9a-f]{128}\z/, application.fetch("SECRET_KEY_BASE"))
    assert_match(/\A[0-9a-f]{64}\z/, database.fetch("POSTGRES_PASSWORD"))
    assert_equal database.fetch("POSTGRES_PASSWORD"), application.fetch("PLEX_DATABASE_PASSWORD")
    assert_match(/\Agigaadmin-[0-9a-f]{32}\z/, application.fetch("PLEX_CLIENT_IDENTIFIER"))
    assert_equal "gigaadmin", compose.fetch("COMPOSE_PROJECT_NAME")
    assert_equal "127.0.0.1", compose.fetch("PLEX_ADMIN_BIND")
    assert_equal "3010", compose.fetch("PLEX_ADMIN_PORT")
    assert_equal "localhost", application.fetch("PLEX_HOST")
    assert_equal "false", application.fetch("PLEX_ASSUME_SSL")
    assert_equal "false", application.fetch("PLEX_FORCE_SSL")
    assert_equal "auto", application.fetch("GIGAADMIN_AUTH_MODE")
    assert_equal "Etc/UTC", application.fetch("TZ")
    %w[PLEX_TOKEN PLEX_MACHINE_IDENTIFIER PLEX_SERVER_BASE_URL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].each do |key|
      assert_equal "", application.fetch(key)
    end
    targets.each do |target|
      assert_equal 0o600, File.stat(File.join(@directory, target)).mode & 0o777
    end
    assert_not_includes output, application.fetch("SECRET_KEY_BASE")
    assert_not_includes output, database.fetch("POSTGRES_PASSWORD")
    assert_empty Dir.glob(File.join(@directory, "tmp/setup.*"))
  end

  test "a second run preserves every generated secret" do
    output, status = run_setup
    assert status.success?, output
    original = targets.to_h { |target| [ target, File.read(File.join(@directory, target)) ] }

    output, status = run_setup

    assert_not status.success?
    assert_includes output, ".env already exists"
    original.each { |target, contents| assert_equal contents, File.read(File.join(@directory, target)) }
  end

  %w[.env .env.production .env.postgres].each do |existing|
    test "refuses an existing #{existing} without creating the other files" do
      File.write(File.join(@directory, existing), "existing-private-content\n")

      output, status = run_setup

      assert_not status.success?
      assert_includes output, "#{existing} already exists"
      assert_equal "existing-private-content\n", File.read(File.join(@directory, existing))
      (targets - [ existing ]).each { |target| assert_not File.exist?(File.join(@directory, target)) }
      assert_not_includes output, "existing-private-content"
    end
  end

  test "refuses a broken symlink at a configuration path" do
    File.symlink("missing-file", File.join(@directory, ".env.production"))

    output, status = run_setup

    assert_not status.success?
    assert_includes output, ".env.production already exists"
    assert File.symlink?(File.join(@directory, ".env.production"))
    assert_not File.exist?(File.join(@directory, ".env"))
    assert_not File.exist?(File.join(@directory, ".env.postgres"))
  end

  test "a missing template leaves no partial configuration" do
    FileUtils.rm(File.join(@directory, ".env.postgres.example"))

    output, status = run_setup

    assert_not status.success?
    assert_includes output, "missing template"
    targets.each { |target| assert_not File.exist?(File.join(@directory, target)) }
  end

  test "a failed random generator leaves no configuration or lock" do
    stub_command("openssl", "exit 1")

    _output, status = run_setup

    assert_not status.success?
    targets.each { |target| assert_not File.exist?(File.join(@directory, target)) }
    assert_empty Dir.glob(File.join(@directory, "tmp/setup.*"))
  end

  test "an unexpected random generator value is rejected without exposing it" do
    stub_command("openssl", "printf 'not-a-secret\\n'")

    output, status = run_setup

    assert_not status.success?
    assert_includes output, "secret generation returned an unexpected value"
    assert_not_includes output, "not-a-secret"
    targets.each { |target| assert_not File.exist?(File.join(@directory, target)) }
    assert_empty Dir.glob(File.join(@directory, "tmp/setup.*"))
  end

  test "a file appearing during publication is preserved and our partial files are removed" do
    stub_command("ln", <<~BASH)
      if [[ "$1" == */.env.production ]]; then
        printf 'created-by-another-process\\n' > "$2/.env.production"
      fi
      exec /bin/ln "$@"
    BASH

    output, status = run_setup

    assert_not status.success?
    assert_includes output, "could not create .env.production"
    assert_equal "created-by-another-process\n", File.read(File.join(@directory, ".env.production"))
    assert_not File.exist?(File.join(@directory, ".env"))
    assert_not File.exist?(File.join(@directory, ".env.postgres"))
    assert_empty Dir.glob(File.join(@directory, "tmp/setup.*"))
  end

  private

  def targets
    %w[.env .env.production .env.postgres]
  end

  def environment_file(name)
    File.readlines(File.join(@directory, name), chomp: true).filter_map do |line|
      next unless line.match?(/\A[A-Z_]+=/)

      line.split("=", 2)
    end.to_h
  end

  def stub_command(name, body)
    path = File.join(@directory, "bin", name)
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  def run_setup
    Open3.capture2e(
      { "PATH" => "#{@directory}/bin:#{ENV.fetch('PATH')}" },
      "bash", File.join(@directory, "scripts/setup"), chdir: Dir.tmpdir
    )
  end
end
