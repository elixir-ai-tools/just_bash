defmodule JustBash.Commands.Local do
  @moduledoc """
  The `local` builtin command - declare local variables within a function.

  In JustBash, `local` simply performs variable assignments in the current scope.
  Since function calls already use isolated environments, this matches the expected
  behavior of local variable declarations.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["local", "declare", "typeset"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, rest} = extract_flags(args)
    bash = process_declarations(bash, rest, flags)
    {Command.ok(""), bash}
  end

  defp extract_flags(args) do
    Enum.split_with(args, &String.starts_with?(&1, "-"))
  end

  defp process_declarations(bash, args, flags) do
    is_assoc = "-A" in flags

    Enum.reduce(args, bash, fn arg, acc ->
      process_arg(arg, acc, is_assoc)
    end)
  end

  defp process_arg(arg, bash, is_assoc) do
    # Handle assignment syntax: name=value
    case String.split(arg, "=", parts: 2) do
      [name, value] when name != "" ->
        env =
          bash.env
          |> Map.put(name, value)
          |> track_local(name)
          |> maybe_mark_assoc(name, is_assoc)

        %{bash | env: env}

      [name] when name != "" ->
        env =
          bash.env
          |> Map.put(name, "")
          |> track_local(name)
          |> maybe_mark_assoc(name, is_assoc)

        %{bash | env: env}

      _ ->
        bash
    end
  end

  defp maybe_mark_assoc(env, name, true), do: Map.put(env, "__assoc__#{name}", "1")
  defp maybe_mark_assoc(env, _name, false), do: env

  # Register a variable name as local so execute_function can revert it
  defp track_local(env, name) do
    case Map.get(env, "__locals__") do
      %MapSet{} = locals -> Map.put(env, "__locals__", MapSet.put(locals, name))
      # Not inside a function — local has no effect on scoping
      _ -> env
    end
  end
end
