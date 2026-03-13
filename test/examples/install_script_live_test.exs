defmodule JustBash.Examples.InstallScriptLiveTest do
  @moduledoc """
  Runs the real Claude Code bootstrap installer script through JustBash
  with LIVE HTTP requests to storage.googleapis.com.

  Everything is real: curl fetches from GCS, jq parses real JSON, shasum/sha256sum
  compute real SHA-256 hashes on the downloaded binary. The only mocks are:

  - `sysctl` — Rosetta 2 detection (macOS kernel query)
  - `ldd` — musl detection (binary inspector)
  - The final `$binary_path install` line — replaced with an echo since we
    can't execute a real binary inside the sandbox

  These tests are tagged `:live` and excluded by default. Run them with:

      mix test --include live

  The full install tests download ~50-200MB binaries and may take 30-60 seconds.
  """

  use ExUnit.Case, async: true

  @moduletag :live

  @fixture_path Path.expand("../fixtures/bootstrap.sh", __DIR__)

  # -- Minimal mocks for OS-specific commands ----------------------------------

  defmodule SysctlCommand do
    @behaviour JustBash.Commands.Command
    @impl true
    def names, do: ["sysctl"]

    @impl true
    def execute(bash, args, _stdin) do
      case args do
        ["-n", "sysctl.proc_translated"] ->
          {%{stdout: "0\n", stderr: "", exit_code: 0}, bash}

        _ ->
          {%{stdout: "", stderr: "sysctl: unknown oid\n", exit_code: 1}, bash}
      end
    end
  end

  defmodule LddCommand do
    @behaviour JustBash.Commands.Command
    @impl true
    def names, do: ["ldd"]

    @impl true
    def execute(bash, _args, _stdin) do
      {%{
         stdout: "linux-vdso.so.1\nlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6\n",
         stderr: "",
         exit_code: 0
       }, bash}
    end
  end

  # -- Helpers -----------------------------------------------------------------

  @mock_commands %{
    "sysctl" => SysctlCommand,
    "ldd" => LddCommand
  }

  defp new_bash(opts) do
    os = Keyword.get(opts, :os, "Darwin")
    arch = Keyword.get(opts, :arch, "arm64")

    JustBash.new(
      commands: @mock_commands,
      env: %{
        "HOME" => "/home/user",
        "JUST_BASH_OS" => os,
        "JUST_BASH_ARCH" => arch
      },
      network: %{enabled: true, allow_list: ["storage.googleapis.com"]}
    )
  end

  @script File.read!(@fixture_path)
          |> String.replace(
            ~r/^"?\$binary_path"? install .+$/m,
            ~S[echo "claude install: simulated"]
          )

  # ============================================================================
  # Lightweight live tests — only fetch version + manifest, no binary download
  # ============================================================================

  describe "live: version and manifest" do
    test "fetches real version string from GCS" do
      bash = new_bash(os: "Darwin", arch: "arm64")

      {result, _} =
        JustBash.exec(bash, """
        version=$(curl -fsSL "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest")
        echo "$version"
        """)

      assert result.exit_code == 0,
             "stderr: #{result.stderr}"

      assert String.trim(result.stdout) =~ ~r/^\d+\.\d+\.\d+/
    end

    test "parses manifest JSON with jq and extracts version" do
      bash = new_bash(os: "Darwin", arch: "arm64")

      {result, _} =
        JustBash.exec(bash, """
        GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
        version=$(curl -fsSL "$GCS/latest")
        manifest=$(curl -fsSL "$GCS/$version/manifest.json")
        echo "$manifest" | jq -r '.version'
        """)

      assert result.exit_code == 0,
             "stderr: #{result.stderr}"

      assert String.trim(result.stdout) =~ ~r/^\d+\.\d+\.\d+/
    end

    test "extracts 64-char hex checksum for darwin-arm64" do
      bash = new_bash(os: "Darwin", arch: "arm64")

      {result, _} =
        JustBash.exec(bash, """
        GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
        version=$(curl -fsSL "$GCS/latest")
        manifest=$(curl -fsSL "$GCS/$version/manifest.json")
        checksum=$(echo "$manifest" | jq -r '.platforms["darwin-arm64"].checksum // empty')
        echo "$checksum"
        """)

      assert result.exit_code == 0,
             "stderr: #{result.stderr}"

      assert String.trim(result.stdout) =~ ~r/^[a-f0-9]{64}$/
    end
  end

  # ============================================================================
  # Full end-to-end — real binary download + real SHA-256 verification
  # ============================================================================

  describe "live: full install" do
    @describetag :live_full
    @describetag timeout: 180_000

    test "darwin-arm64: download, checksum, install" do
      bash = new_bash(os: "Darwin", arch: "arm64")
      {result, bash} = JustBash.exec(bash, @script)

      assert result.exit_code == 0,
             "expected exit 0, got #{result.exit_code}\n" <>
               "stderr: #{result.stderr}\n" <>
               "stdout (first 500): #{String.slice(result.stdout, 0, 500)}"

      assert result.stdout =~ "Setting up Claude Code..."
      assert result.stdout =~ "Installation complete!"

      # Binary should be cleaned up after install
      {ls_result, _} = JustBash.exec(bash, "ls /home/user/.claude/downloads/")
      refute ls_result.stdout =~ "claude-"
    end

    test "linux-x64: download, checksum, install" do
      bash = new_bash(os: "Linux", arch: "x86_64")
      {result, _} = JustBash.exec(bash, @script)

      assert result.exit_code == 0,
             "expected exit 0, got #{result.exit_code}\n" <>
               "stderr: #{result.stderr}"

      assert result.stdout =~ "Installation complete!"
    end
  end
end
