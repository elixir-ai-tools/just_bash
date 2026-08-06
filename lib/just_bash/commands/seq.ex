defmodule JustBash.Commands.Seq do
  @moduledoc "The `seq` command - print a sequence of numbers."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Limit

  @impl true
  def names, do: ["seq"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [last] ->
        case Integer.parse(last) do
          {n, _} -> render(bash, 1..n)
          :error -> {Command.error("seq: invalid argument\n"), bash}
        end

      [first, last] ->
        with {f, _} <- Integer.parse(first),
             {l, _} <- Integer.parse(last) do
          render(bash, f..l)
        else
          _ -> {Command.error("seq: invalid argument\n"), bash}
        end

      [first, incr, last] ->
        with {f, _} <- Integer.parse(first),
             {i, _} <- Integer.parse(incr),
             {l, _} <- Integer.parse(last) do
          render(bash, f..l//i)
        else
          _ -> {Command.error("seq: invalid argument\n"), bash}
        end

      _ ->
        {Command.error("seq: missing operand\n"), bash}
    end
  end

  # `seq 1 100000000` is one step and one command, so neither the step counter
  # nor the interpreter's statement loop can see it. The range is walked under
  # the wall clock instead.
  defp render(bash, range) do
    output =
      range
      |> Limit.enforce_deadline(bash.interpreter.deadline)
      |> Enum.map_join("\n", &to_string/1)

    {Command.ok(output <> "\n"), bash}
  end
end
