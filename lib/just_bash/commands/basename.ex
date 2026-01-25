defmodule JustBash.Commands.Basename do
  @moduledoc "The `basename` command - strip directory and suffix from filenames."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["basename"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [path] ->
        name = get_basename(path)
        {Command.ok(name <> "\n"), bash}

      [path, suffix] ->
        name = get_basename(path)

        name =
          if String.ends_with?(name, suffix),
            do: String.replace_suffix(name, suffix, ""),
            else: name

        {Command.ok(name <> "\n"), bash}

      _ ->
        {Command.error("basename: missing operand\n"), bash}
    end
  end

  # basename "/" returns "/" in bash, but Path.basename("/") returns ""
  defp get_basename("/"), do: "/"

  defp get_basename(path) do
    path
    |> String.trim_trailing("/")
    |> Path.basename()
  end
end
