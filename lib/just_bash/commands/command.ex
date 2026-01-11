defmodule JustBash.Commands.Command do
  @moduledoc """
  Behaviour for bash commands.

  Each command module implements this behaviour, providing a consistent
  interface for command execution.
  """

  alias JustBash.Fs.InMemoryFs

  @type bash :: JustBash.t()
  @type result :: %{stdout: String.t(), stderr: String.t(), exit_code: non_neg_integer()}
  @type execution_result :: {result(), bash()}

  @doc """
  Execute the command with the given arguments and stdin.
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
    InMemoryFs.resolve_path(bash.cwd, path)
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
