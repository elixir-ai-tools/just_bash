defmodule JustBash.Commands.False do
  @moduledoc "The `false` command - do nothing, unsuccessfully."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["false"]

  @impl true
  def execute(bash, _args, _stdin) do
    {Command.error("", 1), bash}
  end
end
