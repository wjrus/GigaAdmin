require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class DeployScriptTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("gigaadmin-deploy-")
    FileUtils.mkdir_p(File.join(@directory, "scripts"))
    FileUtils.mkdir_p(File.join(@directory, "bin"))
    FileUtils.cp(Rails.root.join("scripts/deploy"), File.join(@directory, "scripts/deploy"))
    File.write(File.join(@directory, ".env.production"), "PLEX_HOST=admin.example.test\n")
    File.write(File.join(@directory, ".env.postgres"), "")
    # A worktree uses a .git file, not a directory.
    File.write(File.join(@directory, ".git"), "gitdir: /unused-test-path\n")
    stub_command("git", 'if [[ "$1" == rev-parse ]]; then echo abc123; fi')
    stub_command("docker", <<~BASH)
      if [[ "$*" == "compose --profile sampling ps --status running --status restarting --services" ]]; then
        printf '%s\\n' "${TEST_RUNNING_SERVICES:-web}"
      elif [[ "$*" == "compose ps -q"* ]]; then
        echo fixture-container
      elif [[ "$*" == "compose port web 80" ]]; then
        printf '%s\\n' "${TEST_PUBLISHED_ENDPOINT-0.0.0.0:3010}"
      elif [[ "$*" == "compose port web 443" ]]; then
        printf '%s\\n' "${TEST_PUBLISHED_TLS_ENDPOINT-0.0.0.0:3443}"
      elif [[ "$*" == "compose exec -T web printenv PLEX_HOST" ]]; then
        printf '%s\\n' "${TEST_PLEX_HOST-admin.example.test}"
      elif [[ "$*" == "compose exec -T web printenv GIGAADMIN_SSL_MODE" ]]; then
        printf '%s\\n' "${TEST_SSL_MODE-proxy}"
      elif [[ "$1" == inspect ]]; then
        echo healthy
      fi
    BASH
    stub_command("curl", "printf '200'")
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "updates an enabled sampler and honors worktree metadata from another directory" do
    output, status = deploy("TEST_RUNNING_SERVICES" => "web\nnow_playing_sampler")

    assert status.success?, output
    assert_includes commands, "git pull --ff-only"
    assert_includes commands, "docker compose --profile sampling ps --status running --status restarting --services"
    assert_includes commands, "docker compose up -d --no-deps web daily_refresh now_playing_sampler"
    assert_includes commands, "curl --connect-timeout 2 --max-time 3"
    assert_not File.exist?(File.join(@directory, "tmp/deploy.lock"))
  end

  test "keeps the sampler opt in" do
    output, status = deploy

    assert status.success?, output
    assert_includes commands, "docker compose up -d --no-deps web daily_refresh\n"
    assert_not_includes commands, "daily_refresh now_playing_sampler"
  end

  test "probes the published port and bind using the running container hostname" do
    File.write(File.join(@directory, ".env"), "PLEX_ADMIN_BIND=192.0.2.15\nPLEX_ADMIN_PORT=3042\n")

    output, status = deploy(
      "TEST_PUBLISHED_ENDPOINT" => "192.0.2.15:3042",
      "TEST_PLEX_HOST" => "configured.example.test"
    )

    assert status.success?, output
    assert_includes commands, "docker compose port web 80"
    assert_includes commands, "docker compose exec -T web printenv PLEX_HOST"
    assert_includes commands, "--noproxy * --globoff -fsS --head --output /dev/null --write-out %{http_code} -H Host: configured.example.test http://192.0.2.15:3042/up"
    assert_not_includes commands, "http://127.0.0.1:3010/up"
  end

  test "maps wildcard IPv4 to loopback and chooses the first published mapping" do
    output, status = deploy("TEST_PUBLISHED_ENDPOINT" => "0.0.0.0:3043\n[::]:3043")

    assert status.success?, output
    assert_includes commands, "http://127.0.0.1:3043/up"
    assert_not_includes commands, "http://0.0.0.0:3043/up"
  end

  test "maps wildcard IPv6 to a bracketed loopback URL" do
    output, status = deploy("TEST_PUBLISHED_ENDPOINT" => "[::]:3044")

    assert status.success?, output
    assert_includes commands, "http://[::1]:3044/up"
  end

  test "retains a specific IPv6 bind in the health URL" do
    output, status = deploy("TEST_PUBLISHED_ENDPOINT" => "[2001:db8::15]:3045")

    assert status.success?, output
    assert_includes commands, "http://[2001:db8::15]:3045/up"
  end

  test "local mode probes HTTP and an omitted mode preserves proxy behavior" do
    %w[local].push("").each do |mode|
      output, status = deploy("TEST_SSL_MODE" => mode)

      assert status.success?, output
      assert_includes commands, "docker compose port web 80"
      assert_not_includes commands, "docker compose port web 443"
    end
  end

  test "letsencrypt probes the TLS port with the public hostname and certificate verification" do
    output, status = deploy(
      "TEST_SSL_MODE" => "letsencrypt",
      "TEST_PUBLISHED_TLS_ENDPOINT" => "0.0.0.0:3443",
      "TEST_PLEX_HOST" => "gigaadmin.example.test"
    )

    assert status.success?, output
    assert_includes commands, "docker compose port web 443"
    assert_not_includes commands, "docker compose port web 80"
    assert_includes commands, "--noproxy * --globoff"
    assert_includes commands, "--resolve gigaadmin.example.test:3443:127.0.0.1 https://gigaadmin.example.test:3443/up"
    assert_not_includes commands, "--insecure"
    assert_not_includes commands, " -k "
  end

  test "letsencrypt maps wildcard IPv6 to a bracketed loopback resolution" do
    output, status = deploy("TEST_SSL_MODE" => "letsencrypt", "TEST_PUBLISHED_TLS_ENDPOINT" => "[::]:443")

    assert status.success?, output
    assert_includes commands, "--resolve admin.example.test:443:[::1] https://admin.example.test:443/up"
  end

  test "letsencrypt retains a specific IPv6 bind in hostname resolution" do
    output, status = deploy("TEST_SSL_MODE" => "letsencrypt", "TEST_PUBLISHED_TLS_ENDPOINT" => "[2001:db8::15]:3445")

    assert status.success?, output
    assert_includes commands, "--resolve admin.example.test:3445:[2001:db8::15] https://admin.example.test:3445/up"
  end

  test "a redirect response is retried rather than accepted as healthy" do
    stub_command("curl", <<~BASH)
      if [[ ! -f "$TEST_COMMAND_LOG.first-curl" ]]; then
        touch "$TEST_COMMAND_LOG.first-curl"
        printf '302'
      else
        printf '200'
      fi
    BASH

    output, status = deploy

    assert status.success?, output
    assert_equal 2, commands.lines.count { |line| line.start_with?("curl ") }
    assert_includes output, "returned HTTP 200"
  end

  test "a failed curl request is retried even if it emits a success status" do
    stub_command("curl", <<~BASH)
      printf '200'
      if [[ ! -f "$TEST_COMMAND_LOG.first-curl" ]]; then
        touch "$TEST_COMMAND_LOG.first-curl"
        exit 60
      fi
    BASH

    output, status = deploy("TEST_SSL_MODE" => "letsencrypt")

    assert status.success?, output
    assert_equal 2, commands.lines.count { |line| line.start_with?("curl ") }
  end

  test "rejects an unsafe public hostname before making a request" do
    output, status = deploy("TEST_SSL_MODE" => "letsencrypt", "TEST_PLEX_HOST" => "https://admin.example.test/path")

    assert_not status.success?
    assert_includes output, "PLEX_HOST must be a hostname"
    assert_not_includes commands, "curl "
  end

  test "rejects an unrecognized SSL mode" do
    output, status = deploy("TEST_SSL_MODE" => "invalid")

    assert_not status.success?
    assert_includes output, "GIGAADMIN_SSL_MODE must be local, proxy, or letsencrypt"
    assert_not_includes commands, "curl "
  end

  test "rejects an out of range published TLS port" do
    output, status = deploy("TEST_SSL_MODE" => "letsencrypt", "TEST_PUBLISHED_TLS_ENDPOINT" => "0.0.0.0:65536")

    assert_not status.success?
    assert_includes output, "web has no usable published TCP port"
    assert_not_includes commands, "curl "
  end

  test "fails clearly when the web port is not published" do
    output, status = deploy("TEST_PUBLISHED_ENDPOINT" => "")

    assert_not status.success?
    assert_includes output, "web has no usable published TCP port"
    assert_not_includes commands, "curl "
    assert_not File.exist?(File.join(@directory, "tmp/deploy.lock"))
  end

  test "rejects a malformed published endpoint before requesting HTTP" do
    output, status = deploy("TEST_PUBLISHED_ENDPOINT" => "127.0.0.1:not-a-port")

    assert_not status.success?
    assert_includes output, "web has no usable published TCP port"
    assert_not_includes commands, "curl "
  end

  test "rejects a concurrent deployment before invoking external commands" do
    FileUtils.mkdir_p(File.join(@directory, "tmp/deploy.lock"))

    output, status = deploy

    assert_not status.success?
    assert_includes output, "another deploy holds tmp/deploy.lock"
    assert_equal "", commands
    assert File.directory?(File.join(@directory, "tmp/deploy.lock"))
  end

  test "a build failure releases the lock and does not start services" do
    stub_command("docker", 'if [[ "$*" == "compose build web" ]]; then exit 1; fi')

    output, status = deploy

    assert_not status.success?, output
    assert_not File.exist?(File.join(@directory, "tmp/deploy.lock"))
    assert_not_includes commands, "docker compose up"
  end

  private

  def stub_command(name, body)
    path = File.join(@directory, "bin", name)
    File.write(path, "#!/usr/bin/env bash\nprintf '%s %s\\n' '#{name}' \"$*\" >> \"$TEST_COMMAND_LOG\"\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  def deploy(overrides = {})
    environment = {
      "PATH" => "#{@directory}/bin:#{ENV.fetch('PATH')}",
      "TEST_COMMAND_LOG" => File.join(@directory, "commands.log")
    }.merge(overrides)
    Open3.capture2e(environment, "bash", File.join(@directory, "scripts/deploy"), chdir: Dir.tmpdir)
  end

  def commands
    path = File.join(@directory, "commands.log")
    File.exist?(path) ? File.read(path) : ""
  end
end
