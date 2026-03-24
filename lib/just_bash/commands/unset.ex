defmodule JustBash.Commands.Unset do
  @moduledoc "The `unset` command - unset environment variables."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Limits

  @impl true
  def names, do: ["unset"]

  @impl true
  def execute(bash, args, _stdin) do
    new_env = Enum.reduce(args, bash.env, fn name, acc -> Map.delete(acc, name) end)

    case Limits.replace_env(bash, new_env) do
      {:ok, new_bash} -> {Command.ok(), new_bash}
      {:error, result, new_bash} -> {result, new_bash}
    end
  end
end
