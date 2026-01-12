defmodule JustBash.Commands.Hostname do
  @moduledoc "The `hostname` command - show the system's host name."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["hostname"]

  @impl true
  def execute(bash, _args, _stdin) do
    {Command.ok("localhost\n"), bash}
  end
end
