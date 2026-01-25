defmodule JustBash.BashComparison.Support do
  @moduledoc """
  Shared helper functions for bash comparison tests.

  Provides utilities to run commands in both real bash and JustBash,
  then compare their outputs and exit codes.
  """

  import ExUnit.Assertions

  @doc """
  Runs a command in real bash using System.cmd.
  Returns {output, exit_code}.
  """
  def run_real_bash(cmd) do
    {output, exit_code} = System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
    {output, exit_code}
  end

  @doc """
  Runs a command in JustBash.
  Returns {output, exit_code}.
  """
  def run_just_bash(cmd) do
    bash = JustBash.new()
    {result, _} = JustBash.exec(bash, cmd)
    # Combine stdout/stderr like bash does with stderr_to_stdout
    output = result.stdout <> result.stderr
    {output, result.exit_code}
  end

  @doc """
  Compares the output of a command run in both bash and JustBash.

  ## Options
    * `:ignore_exit` - If true, only compares output and ignores exit codes.
                       Defaults to false.
  """
  def compare_bash(cmd, opts \\ []) do
    {real_output, real_exit} = run_real_bash(cmd)
    {just_output, just_exit} = run_just_bash(cmd)

    ignore_exit = Keyword.get(opts, :ignore_exit, false)

    if ignore_exit do
      assert just_output == real_output,
             "Output mismatch for: #{cmd}\n" <>
               "Real bash: #{inspect(real_output)}\n" <>
               "JustBash:  #{inspect(just_output)}"
    else
      assert {just_output, just_exit} == {real_output, real_exit},
             "Mismatch for: #{cmd}\n" <>
               "Real bash: output=#{inspect(real_output)}, exit=#{real_exit}\n" <>
               "JustBash:  output=#{inspect(just_output)}, exit=#{just_exit}"
    end
  end
end
