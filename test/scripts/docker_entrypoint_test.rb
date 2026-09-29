require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class DockerEntrypointTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("gigaadmin-entrypoint-")
    FileUtils.mkdir_p(File.join(@directory, "bin"))
    FileUtils.cp(Rails.root.join("bin/docker-entrypoint"), File.join(@directory, "bin/docker-entrypoint"))
    write_executable("rails", <<~'BASH')
      printf '%s|%s|%s|%s|%s|%s\n' "$*" "${PLEX_ASSUME_SSL-unset}" "${PLEX_FORCE_SSL-unset}" "${TLS_DOMAIN-unset}" "${THRUSTER_TLS_DOMAIN-unset}" "${THRUSTER_STORAGE_PATH-unset}" >> "$TEST_STARTUP_LOG"
      if [[ "$1" == db:prepare && "${TEST_MIGRATION_FAILURE:-false}" == true ]]; then exit 1; fi
    BASH
    write_executable("thrust", 'exec "$@"')
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "missing mode defaults to external TLS termination and clears inherited TLS domains" do
    output, status = run_entrypoint

    assert status.success?, output
    assert_equal [
      "db:prepare|true|true|unset|unset|unset",
      "server|true|true|unset|unset|unset"
    ], startup_log
  end

  test "local mode disables HTTPS assumptions and built-in certificate provisioning" do
    output, status = run_entrypoint("GIGAADMIN_SSL_MODE" => "local")

    assert status.success?, output
    assert_equal [
      "db:prepare|false|false|unset|unset|unset",
      "server|false|false|unset|unset|unset"
    ], startup_log
  end

  test "proxy mode forces secure Rails behavior without enabling built-in TLS" do
    output, status = run_entrypoint("GIGAADMIN_SSL_MODE" => "proxy")

    assert status.success?, output
    assert_equal "server|true|true|unset|unset|unset", startup_log.last
  end

  test "letsencrypt mode configures the selected hostname and persistent certificate storage before preparation" do
    output, status = run_entrypoint("GIGAADMIN_SSL_MODE" => "letsencrypt", "PLEX_HOST" => "plex-admin.example.com")

    assert status.success?, output
    assert_equal [
      "db:prepare|true|true|unset|plex-admin.example.com|/rails/storage/thruster",
      "server|true|true|unset|plex-admin.example.com|/rails/storage/thruster"
    ], startup_log
  end

  test "letsencrypt keeps an explicitly configured storage path" do
    output, status = run_entrypoint("GIGAADMIN_SSL_MODE" => "letsencrypt", "THRUSTER_STORAGE_PATH" => "/certificates")

    assert status.success?, output
    assert_equal "server|true|true|unset|admin.example.com|/certificates", startup_log.last
  end

  test "invalid explicit modes fail before preparing databases or running a command" do
    [ "", "automatic", "https" ].each do |mode|
      output, status = run_entrypoint("GIGAADMIN_SSL_MODE" => mode)

      assert_not status.success?
      assert_includes output, "GIGAADMIN_SSL_MODE must be local, letsencrypt, or proxy"
      assert_empty startup_log
    end
  end

  test "letsencrypt rejects non-hostname input before touching the database" do
    hosts = [ nil, "", "localhost", "admin.localhost", "127.0.0.1", "::1", "[2001:db8::1]",
      "https://admin.example.com", "admin.example.com:443", "admin.example.com/path", "*.example.com",
      "-admin.example.com", "admin-.example.com", "admin..example.com", "admin.example.com\n",
      "a" * 64 + ".example.com", ([ "a" * 63 ] * 4).join(".") ]

    hosts.each do |hostname|
      output, status = run_entrypoint("GIGAADMIN_SSL_MODE" => "letsencrypt", "PLEX_HOST" => hostname)

      assert_not status.success?, "Accepted invalid hostname #{hostname.inspect}"
      assert_includes output, "GigaAdmin startup failed:"
      assert_empty startup_log
    end
  end

  test "non-server commands receive the selected TLS environment without preparing databases" do
    output, status = run_entrypoint({ "GIGAADMIN_SSL_MODE" => "local" }, [ "./bin/rails", "plex:refresh" ])

    assert status.success?, output
    assert_equal [ "plex:refresh|false|false|unset|unset|unset" ], startup_log
  end

  test "failed database preparation prevents the server from starting" do
    output, status = run_entrypoint("TEST_MIGRATION_FAILURE" => "true")

    assert_not status.success?, output
    assert_equal [ "db:prepare|true|true|unset|unset|unset" ], startup_log
  end

  private

  def run_entrypoint(overrides = {}, command = [ "./bin/thrust", "./bin/rails", "server" ])
    environment = {
      "GIGAADMIN_SSL_MODE" => nil,
      "PLEX_HOST" => "admin.example.com",
      "PLEX_ASSUME_SSL" => "false",
      "PLEX_FORCE_SSL" => "false",
      "TLS_DOMAIN" => "old.example.com",
      "THRUSTER_TLS_DOMAIN" => "other.example.com",
      "THRUSTER_STORAGE_PATH" => nil,
      "TEST_MIGRATION_FAILURE" => nil,
      "TEST_STARTUP_LOG" => File.join(@directory, "startup.log")
    }.merge(overrides)
    Open3.capture2e(environment, "bash", "-e", "./bin/docker-entrypoint", *command, chdir: @directory)
  end

  def startup_log
    path = File.join(@directory, "startup.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def write_executable(name, body)
    path = File.join(@directory, "bin", name)
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end
end
