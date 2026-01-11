defmodule JustBash.Commands.Seq do
  @moduledoc "The `seq` command - print a sequence of numbers."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["seq"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [last] ->
        case Integer.parse(last) do
          {n, _} ->
            output = Enum.map_join(1..n, "\n", &to_string/1) <> "\n"
            {Command.ok(output), bash}

          :error ->
            {Command.error("seq: invalid argument\n"), bash}
        end

      [first, last] ->
        with {f, _} <- Integer.parse(first),
             {l, _} <- Integer.parse(last) do
          output = Enum.map_join(f..l, "\n", &to_string/1) <> "\n"
          {Command.ok(output), bash}
        else
          _ -> {Command.error("seq: invalid argument\n"), bash}
        end

      [first, incr, last] ->
        with {f, _} <- Integer.parse(first),
             {i, _} <- Integer.parse(incr),
             {l, _} <- Integer.parse(last) do
          range = f..l//i
          output = Enum.map_join(range, "\n", &to_string/1) <> "\n"
          {Command.ok(output), bash}
        else
          _ -> {Command.error("seq: invalid argument\n"), bash}
        end

      _ ->
        {Command.error("seq: missing operand\n"), bash}
    end
  end
end
