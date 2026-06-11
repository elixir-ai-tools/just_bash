defmodule JustBash.Commands.GitTest do
  use ExUnit.Case, async: false

  @moduletag :git_fs
  @moduletag timeout: 120_000

  @skills_url "https://github.com/anthropics/skills"

  describe "git disabled (default)" do
    test "git clone returns error when git is not enabled" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "git clone #{@skills_url}")
      assert result.exit_code == 127
      assert result.stderr =~ "git access is disabled"
    end

    test "git with no args returns error when disabled" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "git")
      assert result.exit_code == 127
    end
  end

  describe "git clone" do
    setup do
      bash = JustBash.new(git: %{enabled: true})
      %{bash: bash}
    end

    test "clones a public repo and mounts it", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "git clone #{@skills_url}")
      assert result.exit_code == 0
      assert result.stdout =~ "Cloning into 'skills'"

      {result, _bash} = JustBash.exec(bash, "ls /home/user/skills")
      assert result.exit_code == 0
      assert result.stdout != ""
    end

    test "clones into explicit path", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /repo")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "ls /repo")
      assert result.exit_code == 0
      assert result.stdout != ""
    end

    test "clone is writable by default", %{bash: bash} do
      {_result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /repo")

      {result, bash} = JustBash.exec(bash, "echo 'hello' > /repo/test.txt")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "cat /repo/test.txt")
      assert result.stdout =~ "hello"
    end

    test "clone into existing mount fails", %{bash: bash} do
      {_result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /repo")
      {result, _bash} = JustBash.exec(bash, "git clone #{@skills_url} /repo")
      assert result.exit_code == 128
      assert result.stderr =~ "already exists"
    end

    test "clone with no url fails", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "git clone")
      assert result.exit_code == 128
      assert result.stderr =~ "must specify a repository"
    end

    test "unknown subcommand fails", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "git status")
      assert result.exit_code == 1
      assert result.stderr =~ "not a git command"
    end

    test "can read files from cloned repo", %{bash: bash} do
      {_result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /skills")

      {result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {result, _bash} = JustBash.exec(bash, "cat /skills/#{md_file}")
        assert result.exit_code == 0
        assert result.stdout != ""
      end
    end

    test "can cd into cloned repo", %{bash: bash} do
      {_result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /skills")

      {result, bash} = JustBash.exec(bash, "cd /skills && pwd")
      assert result.stdout =~ "/skills"

      {result, _bash} = JustBash.exec(bash, "cd /skills && ls")
      assert result.exit_code == 0
      assert result.stdout != ""
    end

    test "clone strips .git suffix from url for default name", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "git clone #{@skills_url}.git")
      assert result.stdout =~ "Cloning into 'skills'"

      {result, _bash} = JustBash.exec(bash, "ls /home/user/skills")
      assert result.exit_code == 0
    end

    test "credentials are not visible via env or echo", %{bash: _bash} do
      bash = JustBash.new(git: %{enabled: true, credentials: {:bearer, "super_secret_token"}})

      {result, _bash} = JustBash.exec(bash, "env")
      refute result.stdout =~ "super_secret_token"

      {result, _bash} = JustBash.exec(bash, "echo $GIT_TOKEN $GIT_CREDENTIALS $GIT_AUTH")
      refute result.stdout =~ "super_secret_token"

      {result, _bash} = JustBash.exec(bash, "printenv")
      refute result.stdout =~ "super_secret_token"

      {result, _bash} = JustBash.exec(bash, "set")
      refute result.stdout =~ "super_secret_token"
    end
  end

  describe "multi-clone workflow" do
    test "can clone multiple repos into different paths" do
      bash = JustBash.new(git: %{enabled: true})

      {result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /repo1")
      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /repo2")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "ls /repo1 && ls /repo2")
      assert result.exit_code == 0
    end

    test "clone + local files coexist" do
      bash = JustBash.new(git: %{enabled: true})

      {_result, bash} = JustBash.exec(bash, "git clone #{@skills_url} /repo")
      {_result, bash} = JustBash.exec(bash, "echo 'local' > /tmp/local.txt")

      {result, _bash} = JustBash.exec(bash, "ls / | sort")
      assert result.stdout =~ "repo"
      assert result.stdout =~ "tmp"
    end
  end
end
