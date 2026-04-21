defmodule JustBash.FS.GitFSMCPTest do
  @moduledoc """
  Integration test: mount the Model Context Protocol specification repository
  and explore it the way a real coding agent would — no LLM, just the shell
  commands an agent would issue to understand an unfamiliar codebase.

  The sequence mirrors a realistic agent loop:
    1. Orient — survey top-level structure
    2. Read    — consume key documents
    3. Search  — grep for concepts and definitions
    4. Count   — get a sense of scale
    5. Refine  — drill into specifics based on earlier findings

  Run with:

      mix test test/just_bash/fs/git_fs_mcp_test.exs --include live
  """

  use ExUnit.Case, async: false

  @moduletag :live

  alias JustBash.FS
  alias JustBash.FS.GitFS

  @mcp_url "https://github.com/modelcontextprotocol/modelcontextprotocol"

  setup_all do
    unless Code.ensure_loaded?(Exgit) do
      raise ExUnit.SkipError,
            "exgit not available — add {:exgit, github: \"ivarvong/exgit\", branch: \"main\"} to deps"
    end

    # Lazy clone first, then materialise — one network round-trip covers
    # the whole suite. All ls/stat/cat/grep calls below are in-memory.
    state = GitFS.new(url: @mcp_url, lazy: true) |> GitFS.prefetch()
    {:ok, fs} = FS.mount(FS.new(), "/mcp", state)
    bash = JustBash.new(fs: fs)

    %{bash: bash}
  end

  # ---------------------------------------------------------------------------
  # Step 1: Orient — what is this repo?
  # ---------------------------------------------------------------------------

  describe "orient: survey top-level structure" do
    test "ls /mcp shows expected top-level entries", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp")
      assert r.exit_code == 0
      assert r.stdout =~ "README.md"
      assert r.stdout =~ "schema"
      assert r.stdout =~ "docs"
      assert r.stdout =~ "CONTRIBUTING.md"
    end

    test "ls /mcp/schema reveals versioned schema directories", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/schema")
      assert r.exit_code == 0
      versions = r.stdout |> String.split("\n", trim: true)
      assert versions != []
      # at least one version dir is ISO-date shaped (there may also be a "draft" dir)
      assert Enum.any?(versions, &String.match?(&1, ~r/^\d{4}-\d{2}-\d{2}$/))
    end

    test "ls /mcp/schema/<latest> has schema.ts and schema.json", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/schema")
      latest = r.stdout |> String.split("\n", trim: true) |> Enum.sort() |> List.last()

      {r, _} = JustBash.exec(bash, "ls /mcp/schema/#{latest}")
      assert r.exit_code == 0
      assert r.stdout =~ "schema.ts"
      assert r.stdout =~ "schema.json"
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Read — consume key documents
  # ---------------------------------------------------------------------------

  describe "read: consume key documents" do
    test "cat README.md returns the project overview", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /mcp/README.md")
      assert r.exit_code == 0
      assert r.stdout =~ "Model Context Protocol"
      assert r.stdout =~ "schema"
    end

    test "cat CONTRIBUTING.md returns contribution guidelines", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "cat /mcp/CONTRIBUTING.md")
      assert r.exit_code == 0
      assert String.length(r.stdout) > 200
    end

    test "wc -l README.md gives a line count", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "wc -l /mcp/README.md")
      assert r.exit_code == 0
      count = r.stdout |> String.split() |> hd() |> String.to_integer()
      assert count > 5
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Search — grep for the three core MCP primitives
  # ---------------------------------------------------------------------------

  describe "search: grep for core MCP concepts" do
    test "grep finds 'tools' defined in the schema", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -rl tools /mcp/schema")
      assert r.exit_code == 0
      assert r.stdout =~ "schema"
    end

    test "grep finds 'resources' defined in the schema", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -rl resources /mcp/schema")
      assert r.exit_code == 0
      assert r.stdout =~ "schema"
    end

    test "grep finds 'prompts' defined in the schema", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -rl prompts /mcp/schema")
      assert r.exit_code == 0
      assert r.stdout =~ "schema"
    end

    test "grep finds CallToolResult — the tools call response type", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -r CallToolResult /mcp/schema")
      assert r.exit_code == 0
      assert r.stdout =~ "CallToolResult"
    end

    test "grep finds sampling in the schema (LLM sampling primitive)", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "grep -rl sampling /mcp/schema")
      assert r.exit_code == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4: Count — get a sense of scale
  # ---------------------------------------------------------------------------

  describe "count: understand the scale of the spec" do
    test "schema.ts is a substantial file (> 100 lines)", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/schema")
      latest = r.stdout |> String.split("\n", trim: true) |> Enum.sort() |> List.last()

      {r, _} = JustBash.exec(bash, "wc -l /mcp/schema/#{latest}/schema.ts")
      assert r.exit_code == 0
      count = r.stdout |> String.split() |> hd() |> String.to_integer()
      assert count > 100
    end

    test "grep -c counts interface definitions in schema.ts", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/schema")
      latest = r.stdout |> String.split("\n", trim: true) |> Enum.sort() |> List.last()

      {r, _} = JustBash.exec(bash, "grep -c interface /mcp/schema/#{latest}/schema.ts")
      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count > 10
    end

    test "ls /mcp/docs | wc -l counts documentation sections", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/docs | wc -l")
      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Step 5: Refine — drill into a specific concept end to end
  # ---------------------------------------------------------------------------

  describe "refine: drill into the tools primitive" do
    test "find CallToolRequest and CallToolResult definitions back to back", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/schema")
      latest = r.stdout |> String.split("\n", trim: true) |> Enum.sort() |> List.last()
      schema_ts = "/mcp/schema/#{latest}/schema.ts"

      # Both request and result types must exist
      {req_r, _} = JustBash.exec(bash, "grep CallToolRequest #{schema_ts}")
      {res_r, _} = JustBash.exec(bash, "grep CallToolResult #{schema_ts}")

      assert req_r.exit_code == 0
      assert res_r.exit_code == 0
      assert req_r.stdout =~ "CallToolRequest"
      assert res_r.stdout =~ "CallToolResult"
    end

    test "pipeline: grep tools in schema.ts | wc -l counts tool-related lines", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/schema")
      latest = r.stdout |> String.split("\n", trim: true) |> Enum.sort() |> List.last()

      {r, _} =
        JustBash.exec(bash, "grep -i tool /mcp/schema/#{latest}/schema.ts | wc -l")

      assert r.exit_code == 0
      count = r.stdout |> String.trim() |> String.to_integer()
      assert count > 5
    end

    test "cross-file: schema.json also contains tool definitions", %{bash: bash} do
      {r, _} = JustBash.exec(bash, "ls /mcp/schema")
      latest = r.stdout |> String.split("\n", trim: true) |> Enum.sort() |> List.last()

      {r, _} = JustBash.exec(bash, "grep CallToolResult /mcp/schema/#{latest}/schema.json")
      assert r.exit_code == 0
      assert r.stdout =~ "CallToolResult"
    end
  end
end
