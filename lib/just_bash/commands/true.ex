defmodule JustBash.Commands.True do
  @moduledoc "The `true` and `:` commands - do nothing, successfully."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["true", ":"]

  @impl true
  def execute(bash, _args, _stdin) do
    {Command.ok(), bash}
  end
end
