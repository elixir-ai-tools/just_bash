defmodule JustBash.Examples.InstallScriptTest do
  @moduledoc """
  Runs the real Claude Code bootstrap installer script through JustBash.

  The script is read from test/fixtures/bootstrap.sh — the actual production
  installer downloaded from GCS. It exercises a broad surface of shell features:

    - `set -e` (errexit)
    - `[[ ]]` with `=~` regex matching and `-n`
    - `case` with glob patterns (`MINGW*|MSYS*|CYGWIN*`)
    - Functions with `local` variables (side-effects must propagate)
    - Command substitution `$(...)`
    - `command -v` (builtin)
    - `curl` with network allowlist
    - `jq` for JSON parsing
    - `${VAR:+"..."}` conditional expansion
    - `mkdir -p`, `rm -f`, `cut`, `tr`, `sed`, `grep -q`, `echo`, `chmod`
    - `uname`, `shasum`, `sha256sum` (builtins with configurable env)

  Only two commands still need custom mocks: `sysctl` (Rosetta detection)
  and `ldd` (musl detection) — these are OS-specific inspectors with no
  general-purpose bash equivalent.
  """
  use ExUnit.Case, async: true

  @fixture_path Path.expand("../fixtures/bootstrap.sh", __DIR__)

  # -- Mock HTTP client for GCS bucket ----------------------------------------

  defmodule MockGCS do
    @behaviour JustBash.HttpClient

    @version "1.0.42"

    def version, do: @version

    @impl true
    def request(%{url: url} = _req) do
      checksum = :crypto.hash(:sha256, "FAKE_BINARY_CONTENT") |> Base.encode16(case: :lower)

      cond do
        String.ends_with?(url, "/latest") ->
          {:ok, %{status: 200, headers: [], body: @version}}

        String.contains?(url, "/#{@version}/manifest.json") ->
          manifest = %{
            "version" => @version,
            "platforms" => %{
              "darwin-arm64" => %{"checksum" => checksum, "size" => 50_000_000},
              "darwin-x64" => %{"checksum" => checksum, "size" => 50_000_000},
              "linux-x64" => %{"checksum" => checksum, "size" => 48_000_000},
              "linux-arm64" => %{"checksum" => checksum, "size" => 48_000_000},
              "linux-x64-musl" => %{"checksum" => checksum, "size" => 48_000_000}
            }
          }

          {:ok, %{status: 200, headers: [], body: Jason.encode!(manifest)}}

        String.contains?(url, "/#{@version}/") and String.ends_with?(url, "/claude") ->
          {:ok, %{status: 200, headers: [], body: "FAKE_BINARY_CONTENT"}}

        true ->
          {:ok, %{status: 404, headers: [], body: "Not found"}}
      end
    end
  end

  # -- Remaining mock commands (OS-specific, no bash equivalent) ---------------

  defmodule SysctlCommand do
    @behaviour JustBash.Commands.Command
    @impl true
    def names, do: ["sysctl"]

    @impl true
    def execute(bash, args, _stdin) do
      case args do
        ["-n", "sysctl.proc_translated"] ->
          # Not running under Rosetta
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
      # Not musl
      {%{
         stdout: "linux-vdso.so.1\nlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6\n",
         stderr: "",
         exit_code: 0
       }, bash}
    end
  end

  # -- Helper ------------------------------------------------------------------

  # Only sysctl and ldd still need mocks — everything else is a builtin
  @mock_commands %{
    "sysctl" => SysctlCommand,
    "ldd" => LddCommand
  }

  defp new_bash(opts \\ []) do
    os = Keyword.get(opts, :os, "Darwin")
    arch = Keyword.get(opts, :arch, "arm64")
    extra = Keyword.get(opts, :extra_commands, %{})

    JustBash.new(
      commands: Map.merge(@mock_commands, extra),
      env: %{
        "HOME" => "/home/user",
        "JUST_BASH_OS" => os,
        "JUST_BASH_ARCH" => arch
      },
      network: %{enabled: true, allow_list: ["storage.googleapis.com"]},
      http_client: MockGCS
    )
  end

  # Read the real bootstrap script once at compile time, but replace the line
  # that executes the downloaded binary (`"$binary_path" install ...`) with a
  # simple echo — the binary is a fake blob in our virtual FS and can't be
  # "run" as a real command.
  @real_script File.read!(@fixture_path)
               |> String.replace(
                 ~r/^"?\$binary_path"? install .+$/m,
                 ~S[echo "claude install: simulated"]
               )

  # ============================================================================
  # Tests
  # ============================================================================

  describe "full bootstrap script (from fixture)" do
    test "runs to completion on darwin-arm64" do
      bash = new_bash(os: "Darwin", arch: "arm64")
      {result, _} = JustBash.exec(bash, @real_script)

      assert result.exit_code == 0,
             "expected exit 0, got #{result.exit_code}\nstderr: #{result.stderr}\nstdout: #{result.stdout}"

      assert result.stdout =~ "Setting up Claude Code..."
      assert result.stdout =~ "Installation complete!"
    end

    test "runs to completion on darwin-x64" do
      bash = new_bash(os: "Darwin", arch: "x86_64")
      {result, _} = JustBash.exec(bash, @real_script)

      assert result.exit_code == 0,
             "expected exit 0, got #{result.exit_code}\nstderr: #{result.stderr}"
    end

    test "runs to completion on linux-x64" do
      bash = new_bash(os: "Linux", arch: "x86_64")
      {result, _} = JustBash.exec(bash, @real_script)

      assert result.exit_code == 0,
             "expected exit 0, got #{result.exit_code}\nstderr: #{result.stderr}"

      assert result.stdout =~ "Installation complete!"
    end

    test "runs to completion on linux-arm64" do
      bash = new_bash(os: "Linux", arch: "aarch64")
      {result, _} = JustBash.exec(bash, @real_script)

      assert result.exit_code == 0,
             "expected exit 0, got #{result.exit_code}\nstderr: #{result.stderr}"
    end

    test "creates download directory" do
      bash = new_bash()
      {_result, bash} = JustBash.exec(bash, @real_script)
      {result, _} = JustBash.exec(bash, "test -d /home/user/.claude/downloads && echo exists")
      assert result.stdout =~ "exists"
    end

    test "cleans up binary after install" do
      bash = new_bash()
      {_result, bash} = JustBash.exec(bash, @real_script)
      # The script rm -f's the binary at the end
      {result, _} = JustBash.exec(bash, "ls /home/user/.claude/downloads/")
      refute result.stdout =~ "claude-"
    end

    test "checksum is verified with real SHA-256" do
      # Verify our test infrastructure: the mock HTTP checksum must match
      # the real SHA-256 of the fake binary content
      bash = new_bash()
      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code == 0
      # If checksum verification failed, the script would exit non-zero
    end
  end

  describe "platform detection" do
    test "unsupported OS exits with error" do
      bash = new_bash(os: "FreeBSD")
      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code != 0
      assert result.stderr =~ "Unsupported operating system"
    end

    test "unsupported architecture exits with error" do
      bash = new_bash(os: "Linux", arch: "mips")
      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code != 0
      assert result.stderr =~ "Unsupported architecture"
    end

    test "Windows is rejected" do
      bash = new_bash(os: "MINGW64_NT-10.0")
      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code != 0
      assert result.stderr =~ "Windows is not supported"
    end
  end

  describe "target validation" do
    test "no target — runs normally" do
      bash = new_bash()
      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code == 0
    end

    test "accepts 'stable'" do
      bash = new_bash()
      {result, _} = JustBash.exec(bash, "set -- stable\n" <> @real_script)
      assert result.exit_code == 0
    end

    test "accepts 'latest'" do
      bash = new_bash()
      {result, _} = JustBash.exec(bash, "set -- latest\n" <> @real_script)
      assert result.exit_code == 0
    end

    test "accepts semver like 1.2.3" do
      bash = new_bash()
      {result, _} = JustBash.exec(bash, "set -- 1.2.3\n" <> @real_script)
      assert result.exit_code == 0
    end

    test "accepts semver with prerelease like 1.2.3-beta.1" do
      bash = new_bash()
      {result, _} = JustBash.exec(bash, "set -- 1.2.3-beta.1\n" <> @real_script)
      assert result.exit_code == 0
    end

    test "rejects invalid target" do
      bash = new_bash()
      {result, _} = JustBash.exec(bash, "set -- 'not valid!!'\n" <> @real_script)
      assert result.exit_code != 0
      assert result.stderr =~ "Usage"
    end
  end

  describe "dependency detection" do
    test "script runs when curl is available (it's a builtin)" do
      # curl is always available as a builtin, so the script should find it
      bash = new_bash()
      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code == 0
    end
  end

  describe "network allowlist" do
    test "script fails when GCS host is not in allowlist" do
      bash =
        JustBash.new(
          commands: @mock_commands,
          env: %{
            "HOME" => "/home/user",
            "JUST_BASH_OS" => "Darwin",
            "JUST_BASH_ARCH" => "arm64"
          },
          network: %{enabled: true, allow_list: ["example.com"]},
          http_client: MockGCS
        )

      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code != 0
    end

    test "script fails when network is disabled entirely" do
      bash =
        JustBash.new(
          commands: @mock_commands,
          env: %{
            "HOME" => "/home/user",
            "JUST_BASH_OS" => "Darwin",
            "JUST_BASH_ARCH" => "arm64"
          },
          network: %{enabled: false},
          http_client: MockGCS
        )

      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code != 0
    end
  end

  describe "checksum verification" do
    test "fails when checksum does not match" do
      defmodule BadChecksumGCS do
        @behaviour JustBash.HttpClient

        @version "1.0.42"
        # Wrong checksum in manifest
        @bad_checksum "0000000000000000000000000000000000000000000000000000000000000000"

        @impl true
        def request(%{url: url} = _req) do
          cond do
            String.ends_with?(url, "/latest") ->
              {:ok, %{status: 200, headers: [], body: @version}}

            String.contains?(url, "/#{@version}/manifest.json") ->
              manifest = %{
                "version" => @version,
                "platforms" => %{
                  "darwin-arm64" => %{"checksum" => @bad_checksum, "size" => 50_000_000},
                  "darwin-x64" => %{"checksum" => @bad_checksum, "size" => 50_000_000},
                  "linux-x64" => %{"checksum" => @bad_checksum, "size" => 48_000_000},
                  "linux-arm64" => %{"checksum" => @bad_checksum, "size" => 48_000_000}
                }
              }

              {:ok, %{status: 200, headers: [], body: Jason.encode!(manifest)}}

            String.contains?(url, "/#{@version}/") and String.ends_with?(url, "/claude") ->
              {:ok, %{status: 200, headers: [], body: "FAKE_BINARY_CONTENT"}}

            true ->
              {:ok, %{status: 404, headers: [], body: "Not found"}}
          end
        end
      end

      bash =
        JustBash.new(
          commands: @mock_commands,
          env: %{
            "HOME" => "/home/user",
            "JUST_BASH_OS" => "Darwin",
            "JUST_BASH_ARCH" => "arm64"
          },
          network: %{enabled: true, allow_list: ["storage.googleapis.com"]},
          http_client: BadChecksumGCS
        )

      {result, _} = JustBash.exec(bash, @real_script)
      assert result.exit_code != 0
      assert result.stderr =~ "Checksum verification failed"
    end
  end
end
