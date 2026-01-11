defmodule JustBash.Commands.Printf do
  @moduledoc "The `printf` command - format and print data."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["printf"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [format | rest] ->
        output = format_string(format, rest)
        {Command.ok(output), bash}

      [] ->
        {Command.ok(), bash}
    end
  end

  defp format_string(format, args) do
    format
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> apply_args(args)
  end

  defp apply_args(format, []) do
    format
    |> String.replace(~r/%s/, "")
    |> String.replace(~r/%d/, "0")
  end

  defp apply_args(format, [arg | rest]) do
    cond do
      String.contains?(format, "%s") ->
        format |> String.replace("%s", arg, global: false) |> apply_args(rest)

      String.contains?(format, "%d") ->
        num =
          case Integer.parse(arg) do
            {n, _} -> to_string(n)
            :error -> "0"
          end

        format |> String.replace("%d", num, global: false) |> apply_args(rest)

      true ->
        format
    end
  end
end
