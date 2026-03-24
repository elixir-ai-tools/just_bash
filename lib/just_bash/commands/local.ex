defmodule JustBash.Commands.Local do
  @moduledoc """
  The `local` builtin command - declare local variables within a function.

  In JustBash, `local` simply performs variable assignments in the current scope.
  Since function calls already use isolated environments, this matches the expected
  behavior of local variable declarations.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Limits

  @impl true
  def names, do: ["local", "declare", "typeset"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, rest} = extract_flags(args)

    case process_declarations(bash, rest, flags) do
      {:ok, new_bash} -> {Command.ok(""), new_bash}
      {:error, result, new_bash} -> {result, new_bash}
    end
  end

  defp extract_flags(args) do
    Enum.split_with(args, &String.starts_with?(&1, "-"))
  end

  defp process_declarations(bash, args, flags) do
    is_assoc = "-A" in flags

    Enum.reduce_while(args, {:ok, bash}, fn arg, {:ok, acc} ->
      case process_arg(arg, acc, is_assoc) do
        {:ok, new_bash} -> {:cont, {:ok, new_bash}}
        {:error, result, new_bash} -> {:halt, {:error, result, new_bash}}
      end
    end)
  end

  defp process_arg(arg, bash, is_assoc) do
    case String.split(arg, "=", parts: 2) do
      [name, value] when name != "" ->
        with {:ok, bash} <- put_env(bash, name, value) do
          {:ok,
           bash
           |> track_local(name)
           |> maybe_mark_assoc(name, is_assoc)}
        end

      [name] when name != "" ->
        with {:ok, bash} <- put_env(bash, name, "") do
          {:ok,
           bash
           |> track_local(name)
           |> maybe_mark_assoc(name, is_assoc)}
        end

      _ ->
        {:ok, bash}
    end
  end

  defp put_env(bash, name, value) do
    case Limits.put_env(bash, name, value) do
      {:ok, new_bash} -> {:ok, new_bash}
      {:error, result, new_bash} -> {:error, result, new_bash}
    end
  end

  defp maybe_mark_assoc(bash, name, true) do
    new_assoc = MapSet.put(bash.interpreter.assoc_arrays, name)
    %{bash | interpreter: %{bash.interpreter | assoc_arrays: new_assoc}}
  end

  defp maybe_mark_assoc(bash, _name, false), do: bash

  # Register a variable name as local so execute_function can revert it on return.
  # Only has effect when inside a function call (locals tracker is a MapSet).
  # Outside a function, local/declare still sets the variable but doesn't track it.
  defp track_local(bash, name) do
    new_locals = MapSet.put(bash.interpreter.locals, name)
    %{bash | interpreter: %{bash.interpreter | locals: new_locals}}
  end
end
