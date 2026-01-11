defmodule JustBash.Commands.Pwd do
  @moduledoc "The `pwd` command - print working directory."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["pwd"]

  @impl true
  def execute(bash, _args, _stdin) do
    {Command.ok(bash.cwd <> "\n"), bash}
  end
end
