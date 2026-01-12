defmodule JustBash.Commands.Tac do
  @moduledoc "The `tac` command - concatenate and print files in reverse."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["tac"]

  @impl true
  def execute(bash, args, stdin) do
    files = Enum.reject(args, &String.starts_with?(&1, "-"))

    content =
      if files == [] or files == ["-"] do
        stdin
      else
        case read_files(bash, files) do
          {:ok, data} -> data
          {:error, msg} -> {:error, msg}
        end
      end

    case content do
      {:error, msg} ->
        {Command.error(msg), bash}

      data ->
        output = reverse_lines(data)
        {Command.ok(output), bash}
    end
  end

  defp read_files(bash, files) do
    Enum.reduce_while(files, {:ok, ""}, fn file, {:ok, acc} ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case InMemoryFs.read_file(bash.fs, resolved) do
        {:ok, data} -> {:cont, {:ok, acc <> data}}
        {:error, _} -> {:halt, {:error, "tac: #{file}: No such file or directory\n"}}
      end
    end)
  end

  defp reverse_lines(content) do
    lines = String.split(content, "\n", trim: false)

    lines =
      if List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    if lines == [] do
      ""
    else
      Enum.reverse(lines) |> Enum.join("\n") |> Kernel.<>("\n")
    end
  end
end
