defmodule JustBash.Commands.Rev do
  @moduledoc "The `rev` command - reverse lines characterwise."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["rev"]

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
        output = reverse_chars_per_line(data)
        {Command.ok(output), bash}
    end
  end

  defp read_files(bash, files) do
    Enum.reduce_while(files, {:ok, ""}, fn file, {:ok, acc} ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case InMemoryFs.read_file(bash.fs, resolved) do
        {:ok, data} -> {:cont, {:ok, acc <> data}}
        {:error, _} -> {:halt, {:error, "rev: #{file}: No such file or directory\n"}}
      end
    end)
  end

  defp reverse_chars_per_line(content) do
    has_trailing_newline = String.ends_with?(content, "\n")

    lines =
      content
      |> String.split("\n", trim: false)

    lines =
      if has_trailing_newline and List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    reversed = Enum.map_join(lines, "\n", &reverse_string/1)

    if has_trailing_newline do
      reversed <> "\n"
    else
      reversed
    end
  end

  defp reverse_string(str) do
    str
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.join()
  end
end
