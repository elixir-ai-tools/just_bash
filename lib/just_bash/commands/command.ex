defmodule JustBash.Commands.Command do
  @moduledoc """
  Behaviour for bash commands.

  Each command module implements this behaviour, providing a consistent
  interface for command execution.
  """

  alias JustBash.Fs

  @type bash :: JustBash.t()
  # Result map - may include control flow signals (__break__, __continue__, __return__)
  @type result :: map()
  @type execution_result :: {result(), bash()}

  @doc """
  Execute the command with the given arguments and stdin.

  The returned result map must carry `:stdout`, `:stderr`, and `:exit_code`, but **may
  contain extra keys**. The executor preserves them past result validation, dropping only
  internal control-flow signals before the result reaches the shell. This is load-bearing:
  `JustBash.CLI` smuggles its resolved subcommand path through under `:__subcommand__` so
  command telemetry can attribute it (the executor pops it into span metadata). Do not
  tighten the result match to reject unknown keys.
  """
  @callback execute(bash(), args :: [String.t()], stdin :: String.t()) :: execution_result()

  @doc """
  Returns the command name(s) this module handles.
  """
  @callback names() :: [String.t()]

  @doc """
  Resolve a path relative to the current working directory.
  """
  @spec resolve_path(bash(), String.t()) :: String.t()
  def resolve_path(bash, path) do
    Fs.resolve_path(bash.cwd, path)
  end

  @doc """
  Create a successful result with stdout output.
  """
  @spec ok(String.t()) :: result()
  def ok(stdout \\ "") do
    %{stdout: stdout, stderr: "", exit_code: 0}
  end

  @doc """
  Create a failed result with stderr output.
  """
  @spec error(String.t(), non_neg_integer()) :: result()
  def error(stderr, exit_code \\ 1) do
    %{stdout: "", stderr: stderr, exit_code: exit_code}
  end

  @doc """
  Create a result with custom stdout, stderr, and exit code.
  """
  @spec result(String.t(), String.t(), non_neg_integer()) :: result()
  def result(stdout, stderr, exit_code) do
    %{stdout: stdout, stderr: stderr, exit_code: exit_code}
  end
end
