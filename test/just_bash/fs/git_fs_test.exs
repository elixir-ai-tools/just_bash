defmodule JustBash.FS.GitFSTest do
  @moduledoc """
  Live integration tests for GitFS.

  Requires network access and `{:exgit, github: "ivarvong/exgit", branch: "main"}`
  in your deps. Run with:

      mix test test/just_bash/fs/git_fs_test.exs --include live
  """

  use ExUnit.Case, async: true

  @moduletag :live

  alias JustBash.FS
  alias JustBash.FS.GitFS

  # Small public repo — the exgit library itself (~30 Elixir files).
  @test_repo "https://github.com/ivarvong/exgit"

  setup do
    unless Code.ensure_loaded?(Exgit) do
      raise ExUnit.SkipError,
            "exgit not available — add {:exgit, github: \"ivarvong/exgit\", branch: \"main\"} to deps"
    end

    state = GitFS.new(url: @test_repo, lazy: true)

    {:ok, fs} = FS.mount(FS.new(), "/repo", state)
    bash = JustBash.new(fs: fs)

    %{bash: bash}
  end

  describe "ls" do
    test "/ shows standard top-level entries", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo")
      assert r.exit_code == 0
      assert r.stdout =~ "README.md"
      assert r.stdout =~ "mix.exs"
      assert r.stdout =~ "lib"
    end

    test "subdirectory lists correctly", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo/lib/exgit")
      assert r.exit_code == 0
      assert r.stdout =~ "fs.ex"
      assert r.stdout =~ "credentials.ex"
    end

    test "missing path returns non-zero exit", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo/does_not_exist_xyz")
      assert r.exit_code != 0
    end
  end

  describe "cat" do
    test "reads a file from the repo", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /repo/README.md")
      assert r.exit_code == 0
      assert r.stdout =~ "Exgit"
    end

    test "reads a nested file", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /repo/lib/exgit/credentials.ex")
      assert r.exit_code == 0
      assert r.stdout =~ "defmodule Exgit.Credentials"
    end

    test "cat on a directory returns non-zero exit", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /repo/lib")
      assert r.exit_code != 0
    end
  end

  describe "grep" do
    test "grep -r finds pattern across the repo", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -rl defmodule /repo/lib")
      assert r.exit_code == 0
      # every .ex file has a defmodule
      assert r.stdout =~ "lib/"
    end

    test "grep on a single file", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep host_bound /repo/lib/exgit/credentials.ex")
      assert r.exit_code == 0
      assert r.stdout =~ "host_bound"
    end

    test "grep with no match returns exit 1", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep xyzzy_no_such_pattern /repo/README.md")
      assert r.exit_code == 1
    end
  end

  describe "stat / existence" do
    test "[ -e /repo/mix.exs ] succeeds", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "[ -e /repo/mix.exs ]")
      assert r.exit_code == 0
    end

    test "[ -d /repo/lib ] succeeds", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "[ -d /repo/lib ]")
      assert r.exit_code == 0
    end

    test "[ -f /repo/mix.exs ] succeeds", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "[ -f /repo/mix.exs ]")
      assert r.exit_code == 0
    end

    test "[ -e /repo/nonexistent ] fails", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "[ -e /repo/nonexistent_file ]")
      assert r.exit_code != 0
    end
  end

  describe "wc / pipelines" do
    test "wc -l counts lines in a file", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "wc -l /repo/mix.exs")
      assert r.exit_code == 0
      # mix.exs has at least 20 lines
      count = r.stdout |> String.split() |> hd() |> String.to_integer()
      assert count > 20
    end

    test "ls | wc -l counts top-level entries", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo | wc -l")
      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count > 3
    end
  end

  describe "ref option" do
    test "mounting HEAD explicitly works", %{bash: _bash} do
      # HEAD is the default — just sanity-check the option is accepted
      state2 = GitFS.new(url: @test_repo, ref: "HEAD", lazy: true)

      {:ok, fs2} = FS.mount(FS.new(), "/repo2", state2)
      bash2 = JustBash.new(fs: fs2)

      {r, _} = JustBash.exec(bash2, "ls /repo2")
      assert r.exit_code == 0
      assert r.stdout =~ "README.md"
    end
  end
end
