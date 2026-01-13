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
        # Value is already expanded
        %{bash | env: Map.put(bash.env, name, value)}

      [name] when name != "" ->
        # Just declaring a variable without value - set to empty
        %{bash | env: Map.put(bash.env, name, "")}

      _ ->
        bash
    end
  end
end
