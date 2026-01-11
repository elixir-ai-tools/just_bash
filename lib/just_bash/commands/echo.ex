defmodule JustBash.Commands.Echo do
  @moduledoc "The `echo` command - display a line of text."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["echo"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, rest_args} = parse_flags(args)
    output = Enum.join(rest_args, " ")
    output = if flags.n, do: output, else: output <> "\n"
    output = if flags.e, do: interpret_escapes(output), else: output
    {Command.ok(output), bash}
  end

  defp parse_flags(args), do: parse_flags(args, %{n: false, e: false, E: true})

  defp parse_flags(["-n" | rest], flags),
    do: parse_flags(rest, %{flags | n: true})

  defp parse_flags(["-e" | rest], flags),
    do: parse_flags(rest, %{flags | e: true, E: false})

  defp parse_flags(["-E" | rest], flags),
    do: parse_flags(rest, %{flags | E: true, e: false})

  defp parse_flags(["-ne" | rest], flags),
    do: parse_flags(rest, %{flags | n: true, e: true, E: false})

  defp parse_flags(["-en" | rest], flags),
    do: parse_flags(rest, %{flags | n: true, e: true, E: false})

  defp parse_flags(rest, flags), do: {flags, rest}

  defp interpret_escapes(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\\", "\\")
  end
end
