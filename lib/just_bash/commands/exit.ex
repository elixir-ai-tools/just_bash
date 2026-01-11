defmodule JustBash.Commands.Exit do
  @moduledoc "The `exit` command - exit the shell with a status code."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["exit"]

  @impl true
  def execute(bash, args, _stdin) do
    code =
      case args do
        [] ->
          0

        [n | _] ->
          case Integer.parse(n) do
            {num, _} -> num
            :error -> 1
          end
      end

    {Command.result("", "", code), bash}
  end
end
