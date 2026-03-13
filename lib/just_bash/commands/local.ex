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
    # Process each argument as a potential assignment
    # Arguments are already expanded by the executor, so "local a=$1" with $1=hello
    # arrives as "a=hello"
    bash = Enum.reduce(args, bash, &process_arg/2)
    {Command.ok(""), bash}
  end

  defp process_arg(arg, bash) do
    # Handle assignment syntax: name=value
    case String.split(arg, "=", parts: 2) do
      [name, value] when name != "" ->
        # Value is already expanded; track as local for function scope cleanup
        env =
          bash.env
          |> Map.put(name, value)
          |> track_local(name)

        %{bash | env: env}

      [name] when name != "" ->
        # Just declaring a variable without value - set to empty
        env =
          bash.env
          |> Map.put(name, "")
          |> track_local(name)

        %{bash | env: env}

      _ ->
        bash
    end
  end

  # Register a variable name as local so execute_function can revert it
  defp track_local(env, name) do
    case Map.get(env, "__locals__") do
      %MapSet{} = locals -> Map.put(env, "__locals__", MapSet.put(locals, name))
      # Not inside a function — local has no effect on scoping
      _ -> env
    end
  end
end
