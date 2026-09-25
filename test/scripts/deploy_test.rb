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
      if [[ "$*" == "compose ps --status running --status restarting --services" ]]; then
        printf '%s\\n' "${TEST_RUNNING_SERVICES:-web}"
      elif [[ "$*" == "compose ps -q"* ]]; then
        echo fixture-container
      elif [[ "$1" == inspect ]]; then
        echo healthy
      fi
    BASH
    stub_command("curl", "exit 0")
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "updates an enabled sampler and honors worktree metadata from another directory" do
    output, status = deploy("TEST_RUNNING_SERVICES" => "web\nnow_playing_sampler")

    assert status.success?, output
    assert_includes commands, "git pull --ff-only"
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
