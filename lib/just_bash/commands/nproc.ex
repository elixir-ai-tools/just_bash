defmodule JustBash.Commands.Nproc do
  @moduledoc """
  The `nproc` command - print the number of processing units available.

  Returns the value of `JUST_BASH_NPROC` env var, or defaults to "4".
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["nproc"]

  @impl true
  def execute(bash, _args, _stdin) do
    nproc = Map.get(bash.env, "JUST_BASH_NPROC", "4")
    {Command.ok(nproc <> "\n"), bash}
  end
end
