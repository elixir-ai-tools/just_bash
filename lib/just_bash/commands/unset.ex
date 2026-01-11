defmodule JustBash.Commands.Unset do
  @moduledoc "The `unset` command - unset environment variables."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["unset"]

  @impl true
  def execute(bash, args, _stdin) do
    new_env = Enum.reduce(args, bash.env, fn name, acc -> Map.delete(acc, name) end)
    {Command.ok(), %{bash | env: new_env}}
  end
end
