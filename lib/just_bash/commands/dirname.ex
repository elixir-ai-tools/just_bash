defmodule JustBash.Commands.Dirname do
  @moduledoc "The `dirname` command - strip last component from file name."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["dirname"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [path] ->
        dir = get_dirname(path)
        {Command.ok(dir <> "\n"), bash}

      _ ->
        {Command.error("dirname: missing operand\n"), bash}
    end
  end

  # Strip trailing slashes before computing dirname (bash behavior)
  defp get_dirname("/"), do: "/"

  defp get_dirname(path) do
    path
    |> String.trim_trailing("/")
    |> Path.dirname()
  end
end
