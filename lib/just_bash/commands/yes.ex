defmodule JustBash.Commands.Yes do
  @moduledoc """
  The `yes` command - output a string repeatedly.

  Outputs 'y' (or the given string) repeatedly. In the sandboxed environment,
  outputs a bounded number of lines (1000) to prevent infinite output.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @max_lines 1000

  @impl true
  def names, do: ["yes"]

  @impl true
  def execute(bash, args, _stdin) do
    text =
      case args do
        [] -> "y"
        words -> Enum.join(words, " ")
      end

    output = Enum.map_join(1..@max_lines, "\n", fn _ -> text end) <> "\n"

    {Command.ok(output), bash}
  end
end
