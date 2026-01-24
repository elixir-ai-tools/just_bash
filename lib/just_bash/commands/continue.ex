defmodule JustBash.Commands.Continue do
  @moduledoc """
  The `continue` builtin command - resume the next iteration of a loop.

  Usage: continue [n]

  Resumes the next iteration of the innermost enclosing for, while, or until loop.
  If n is specified, resumes the n-th enclosing loop.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Result

  @impl true
  def names, do: ["continue"]

  @impl true
  def execute(bash, args, _stdin) do
    level = parse_level(args)
    {Result.to_map(Result.continue(level)), bash}
  end

  defp parse_level([]), do: 1

  defp parse_level([n | _]) do
    case Integer.parse(n) do
      {level, _} when level > 0 -> level
      _ -> 1
    end
  end
end
