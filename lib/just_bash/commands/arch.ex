defmodule JustBash.Commands.Arch do
  @moduledoc """
  The `arch` command - print machine architecture.

  Equivalent to `uname -m`. Returns `JUST_BASH_ARCH` env var or "x86_64".
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["arch"]

  @impl true
  def execute(bash, _args, _stdin) do
    arch = Map.get(bash.env, "JUST_BASH_ARCH", "x86_64")
    {Command.ok(arch <> "\n"), bash}
  end
end
