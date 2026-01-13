defmodule JustBash.Commands.Read do
  @moduledoc "The `read` command - read a line from stdin into a variable."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["read"]

  @impl true
  def execute(bash, args, stdin) do
    {_flags, var_names} = parse_flags(args)
    var_name = List.first(var_names) || "REPLY"

    # Check for stdin from pipeline (stored in __STDIN__ for group commands)
    effective_stdin =
      cond do
        stdin != "" -> stdin
        Map.has_key?(bash.env, "__STDIN__") -> Map.get(bash.env, "__STDIN__")
        true -> ""
      end

    value =
      if effective_stdin != "",
        do:
          String.trim_trailing(effective_stdin, "\n") |> String.split("\n") |> List.first() || "",
        else: ""

    new_env = Map.put(bash.env, var_name, value)
    {Command.ok(), %{bash | env: new_env}}
  end

  defp parse_flags(args), do: parse_flags(args, %{}, [])

  defp parse_flags(["-r" | rest], flags, vars),
    do: parse_flags(rest, Map.put(flags, :r, true), vars)

  defp parse_flags(["-p", _prompt | rest], flags, vars),
    do: parse_flags(rest, flags, vars)

  defp parse_flags([arg | rest], flags, vars),
    do: parse_flags(rest, flags, vars ++ [arg])

  defp parse_flags([], flags, vars), do: {flags, vars}
end
