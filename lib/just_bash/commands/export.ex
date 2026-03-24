defmodule JustBash.Commands.Export do
  @moduledoc "The `export` command - set environment variables."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Limits

  @impl true
  def names, do: ["export"]

  @impl true
  def execute(bash, args, _stdin) do
    result =
      Enum.reduce_while(args, {:ok, bash}, fn arg, {:ok, acc_bash} ->
        case String.split(arg, "=", parts: 2) do
          [name, value] ->
            case Limits.put_env(acc_bash, name, value) do
              {:ok, new_bash} -> {:cont, {:ok, new_bash}}
              {:error, result, new_bash} -> {:halt, {:error, result, new_bash}}
            end

          [name] ->
            case Limits.put_env(acc_bash, name, Map.get(acc_bash.env, name, "")) do
              {:ok, new_bash} -> {:cont, {:ok, new_bash}}
              {:error, result, new_bash} -> {:halt, {:error, result, new_bash}}
            end
        end
      end)

    case result do
      {:ok, new_bash} -> {Command.ok(), new_bash}
      {:error, limit_result, new_bash} -> {limit_result, new_bash}
    end
  end
end
