defmodule JustBash.Commands.Export do
  @moduledoc "The `export` command - set environment variables."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["export"]

  @impl true
  def execute(bash, args, _stdin) do
    new_env =
      Enum.reduce(args, bash.env, fn arg, acc ->
        case String.split(arg, "=", parts: 2) do
          [name, value] -> Map.put(acc, name, value)
          [name] -> Map.put(acc, name, Map.get(acc, name, ""))
        end
      end)

    {Command.ok(), %{bash | env: new_env}}
  end
end
