defmodule JustBash.Commands.Break do
  @moduledoc """
  The `break` builtin command - exit from a loop.

  Usage: break [n]

  Exits from the innermost enclosing for, while, or until loop.
  If n is specified, breaks out of n levels of loops.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Result

  @impl true
  def names, do: ["break"]

  @impl true
  def execute(bash, args, _stdin) do
    level = parse_level(args)
    {Result.to_map(Result.break(level)), bash}
  end

  defp parse_level([]), do: 1

  defp parse_level([n | _]) do
    case Integer.parse(n) do
      {level, _} when level > 0 -> level
      _ -> 1
    end
  end
end
