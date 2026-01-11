defmodule JustBash.Commands.Sleep do
  @moduledoc "The `sleep` command - delay for a specified time (no-op in simulation)."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["sleep"]

  @impl true
  def execute(bash, _args, _stdin) do
    {Command.ok(), bash}
  end
end
