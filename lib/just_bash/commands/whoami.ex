defmodule JustBash.Commands.Whoami do
  @moduledoc """
  The `whoami` command - print the current user name.

  Returns the value of `USER` env var, or derives it from `HOME`, or defaults to "user".
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["whoami"]

  @impl true
  def execute(bash, _args, _stdin) do
    user =
      Map.get(bash.env, "USER") ||
        Map.get(bash.env, "LOGNAME") ||
        bash.env |> Map.get("HOME", "/home/user") |> Path.basename()

    {Command.ok(user <> "\n"), bash}
  end
end
