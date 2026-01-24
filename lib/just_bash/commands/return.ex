defmodule JustBash.Commands.Return do
  @moduledoc """
  The `return` builtin command - return from a function.

  Usage: return [n]

  Returns from a function with exit code n (default: $?).
  If not inside a function, behaves like exit in a sourced script.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Result

  @impl true
  def names, do: ["return"]

  @impl true
  def execute(bash, args, _stdin) do
    exit_code = parse_exit_code(bash, args)
    {Result.to_map(Result.return(exit_code)), bash}
  end

  defp parse_exit_code(bash, []) do
    # Default to last exit code
    Map.get(bash.env, "?", "0") |> String.to_integer()
  end

  defp parse_exit_code(_bash, [n | _]) do
    case Integer.parse(n) do
      # Exit codes are 0-255
      {code, _} -> rem(code, 256)
      :error -> 0
    end
  end
end
