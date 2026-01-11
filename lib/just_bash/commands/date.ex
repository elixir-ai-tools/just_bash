defmodule JustBash.Commands.Date do
  @moduledoc "The `date` command - display the current date and time."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["date"]

  @impl true
  def execute(bash, _args, _stdin) do
    now = DateTime.utc_now()
    output = Calendar.strftime(now, "%a %b %d %H:%M:%S UTC %Y") <> "\n"
    {Command.ok(output), bash}
  end
end
