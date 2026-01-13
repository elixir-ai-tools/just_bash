defmodule JustBash.Commands.Shift do
  @moduledoc """
  The `shift` builtin command - shift positional parameters.

  Usage: shift [n]

  Shifts positional parameters to the left by n (default 1).
  $2 becomes $1, $3 becomes $2, etc.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["shift"]

  @impl true
  def execute(bash, args, _stdin) do
    n = parse_count(args)

    # Get current positional parameters
    count = Map.get(bash.env, "#", "0") |> String.to_integer()

    if n > count do
      # Can't shift more than we have
      {Command.error("shift: shift count out of range\n", 1), bash}
    else
      # Build new positional parameters
      new_count = count - n

      new_env =
        bash.env
        # Clear old positional parameters
        |> clear_positional(count)
        # Set new positional parameters (shifted)
        |> set_shifted_positional(bash.env, n, new_count)
        # Update special variables
        |> Map.put("#", to_string(new_count))
        |> update_at_and_star(n, new_count)

      {Command.ok(""), %{bash | env: new_env}}
    end
  end

  defp parse_count([]), do: 1

  defp parse_count([n | _]) do
    case Integer.parse(n) do
      {count, _} when count >= 0 -> count
      _ -> 1
    end
  end

  defp clear_positional(env, count) do
    1..max(count, 1)
    |> Enum.reduce(env, fn i, acc ->
      Map.delete(acc, to_string(i))
    end)
  end

  defp set_shifted_positional(env, old_env, shift, new_count) do
    1..max(new_count, 0)
    |> Enum.reduce(env, fn new_pos, acc ->
      old_pos = new_pos + shift
      value = Map.get(old_env, to_string(old_pos), "")
      Map.put(acc, to_string(new_pos), value)
    end)
  end

  defp update_at_and_star(env, _shift, new_count) do
    args =
      1..max(new_count, 0)
      |> Enum.map(&Map.get(env, to_string(&1), ""))

    env
    |> Map.put("@", Enum.join(args, " "))
    |> Map.put("*", Enum.join(args, " "))
  end
end
