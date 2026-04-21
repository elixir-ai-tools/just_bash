defmodule JustBash.FS.GitFSAgentTest do
  @moduledoc """
  Integration test: mount the just_bash repository (main branch) and explore
  it the way a real coding agent would — no LLM, just the shell commands an
  agent would issue to understand an unfamiliar Elixir codebase.

  The sequence mirrors a realistic agent loop:
    1. Orient  — survey top-level structure
    2. Read    — consume key documents
    3. Search  — grep for concepts and definitions
    4. Count   — get a sense of scale
    5. Refine  — drill into specifics based on earlier findings

  Run with:

      mix test test/just_bash/fs/git_fs_agent_test.exs --include live
  """

  use ExUnit.Case, async: false

  @moduletag :live

  alias JustBash.FS
  alias JustBash.FS.GitFS

  @repo_url "https://github.com/elixir-ai-tools/just_bash"

  setup_all do
    unless Code.ensure_loaded?(Exgit) do
      raise ExUnit.SkipError,
            "exgit not available — add {:exgit, github: \"ivarvong/exgit\", branch: \"main\"} to deps"
    end

    # Lazy clone + tree prefetch: ls/stat are in-memory, blobs fetched on
    # demand. Materialize before grep so all file reads are in-memory too.
    state =
      GitFS.new(url: @repo_url, lazy: true)
      |> GitFS.materialize()

    {:ok, fs} = FS.mount(FS.new(), "/repo", state)
    bash = JustBash.new(fs: fs)

    %{bash: bash}
  end

  # ---------------------------------------------------------------------------
  # Step 1: Orient — what is this repo?
  # ---------------------------------------------------------------------------

  describe "orient: survey top-level structure" do
    test "ls /repo shows expected top-level entries", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo")
      assert r.exit_code == 0
      assert r.stdout =~ "mix.exs"
      assert r.stdout =~ "lib"
      assert r.stdout =~ "test"
      assert r.stdout =~ "README.md"
    end

    test "ls /repo/lib/just_bash shows core modules", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo/lib/just_bash")
      assert r.exit_code == 0
      assert r.stdout =~ "commands"
      assert r.stdout =~ "interpreter"
    end

    test "ls /repo/lib/just_bash/commands shows many command modules", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo/lib/just_bash/commands | wc -l")
      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count > 20
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Read — consume key documents
  # ---------------------------------------------------------------------------

  describe "read: consume key documents" do
    test "cat mix.exs shows project metadata", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /repo/mix.exs")
      assert r.exit_code == 0
      assert r.stdout =~ "just_bash"
      assert r.stdout =~ "deps"
    end

    test "cat README.md returns project overview", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /repo/README.md")
      assert r.exit_code == 0
      assert String.length(r.stdout) > 200
    end

    test "wc -l on grep.ex gives a sense of its size", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "wc -l /repo/lib/just_bash/commands/grep.ex")
      assert r.exit_code == 0
      count = r.stdout |> String.split() |> hd() |> String.to_integer()
      assert count > 50
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Search — grep for core concepts
  # ---------------------------------------------------------------------------

  describe "search: grep for core concepts" do
    test "grep finds all command modules via @behaviour", %{bash: bash} do
      {r, _} =
        JustBash.exec(bash, "grep -rl '@behaviour' /repo/lib/just_bash/commands")

      assert r.exit_code == 0
      assert r.stdout =~ "grep.ex"
      assert r.stdout =~ "echo.ex"
    end

    test "grep finds defmodule declarations across lib", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -r 'defmodule JustBash' /repo/lib | wc -l")
      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count > 10
    end

    test "grep finds execute/3 implementations in commands", %{bash: bash} do
      {r, _} =
        JustBash.exec(bash, "grep -rl 'def execute' /repo/lib/just_bash/commands")

      assert r.exit_code == 0
      assert r.stdout =~ "grep.ex"
      assert r.stdout =~ "echo.ex"
    end

    test "grep finds the lexer module", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -r 'defmodule.*Lexer' /repo/lib")
      assert r.exit_code == 0
      assert r.stdout =~ "Lexer"
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4: Count — understand the scale of the codebase
  # ---------------------------------------------------------------------------

  describe "count: understand scale" do
    test "interpreter has multiple source files", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /repo/lib/just_bash/interpreter | wc -l")
      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count >= 3
    end

    test "grep.ex has many lines", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "wc -l /repo/lib/just_bash/commands/grep.ex")
      assert r.exit_code == 0
      count = r.stdout |> String.split() |> hd() |> String.to_integer()
      assert count > 100
    end

    test "pipeline: count @impl true in a command file", %{bash: bash} do
      {r, _} =
        JustBash.exec(bash, "grep '@impl true' /repo/lib/just_bash/commands/grep.ex | wc -l")

      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Step 5: Refine — drill into a specific command end to end
  # ---------------------------------------------------------------------------

  describe "refine: drill into the grep command" do
    test "grep.ex defines names/0 returning ['grep']", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep 'def names' /repo/lib/just_bash/commands/grep.ex")
      assert r.exit_code == 0
      assert r.stdout =~ "names"
    end

    test "grep.ex handles -r flag for recursive search", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep ':r' /repo/lib/just_bash/commands/grep.ex")
      assert r.exit_code == 0
    end

    test "pipeline: find all flag atoms defined in grep.ex", %{bash: bash} do
      {r, _} =
        JustBash.exec(
          bash,
          "grep -o ':[a-z_]*' /repo/lib/just_bash/commands/grep.ex | sort | uniq | wc -l"
        )

      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count > 5
    end

    test "cat just_bash.ex is the main public API module", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /repo/lib/just_bash.ex")
      assert r.exit_code == 0
      assert r.stdout =~ "defmodule JustBash"
      assert r.stdout =~ "def exec"
    end
  end
end
