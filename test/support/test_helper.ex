defmodule JustBash.TestHelper do
  @moduledoc """
  Helper functions for JustBash tests.
  """

  @doc """
  Create a new bash environment with optional files and env vars.
  """
  def bash(opts \\ []) do
    JustBash.new(opts)
  end

  @doc """
  Execute a command and return {result, bash}.
  """
  def exec(bash, cmd) do
    JustBash.exec(bash, cmd)
  end

  @doc """
  Execute a command and return just the result.
  """
  def exec!(bash, cmd) do
    {result, _} = JustBash.exec(bash, cmd)
    result
  end

  @doc """
  Assert command succeeds with expected stdout.
  """
  defmacro assert_output(bash, cmd, expected) do
    quote do
      {result, _} = JustBash.exec(unquote(bash), unquote(cmd))

      assert result.exit_code == 0,
             "Expected exit code 0, got #{result.exit_code}: #{result.stderr}"

      assert result.stdout == unquote(expected)
    end
  end

  @doc """
  Assert command fails with expected exit code.
  """
  defmacro assert_fails(bash, cmd, exit_code \\ 1) do
    quote do
      {result, _} = JustBash.exec(unquote(bash), unquote(cmd))
      assert result.exit_code == unquote(exit_code)
    end
  end

  @doc """
  Assert command fails and stderr contains message.
  """
  defmacro assert_error(bash, cmd, message) do
    quote do
      {result, _} = JustBash.exec(unquote(bash), unquote(cmd))
      assert result.exit_code != 0
      assert result.stderr =~ unquote(message)
    end
  end
end
