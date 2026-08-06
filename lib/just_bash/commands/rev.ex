defmodule JustBash.Commands.Rev do
  @moduledoc "The `rev` command - reverse lines characterwise."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["rev"]

  @impl true
  def execute(bash, args, stdin) do
    case read_operands(bash, StdinOperand.operands(args), stdin) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, data, fs} ->
        {Command.ok(reverse_chars_per_line(data)), %{bash | fs: fs}}
    end
  end

  # `rev` is line-local, so reading the operands in the order given is all it
  # takes to put each one's lines where they belong — unlike `tac`, which has
  # to reverse each operand on its own.
  defp read_operands(bash, files, stdin) do
    files
    |> defaults_to_stdin()
    |> Enum.reduce_while({:ok, "", bash.fs}, fn file, {:ok, acc, fs} ->
      case StdinOperand.read(fs, bash.cwd, file, stdin) do
        {:ok, data, fs} -> {:cont, {:ok, acc <> data, fs}}
        {:error, error} -> {:halt, {:error, "rev: #{file}: #{FS.strerror(error)}\n"}}
      end
    end)
  end

  defp defaults_to_stdin([]), do: ["-"]
  defp defaults_to_stdin(files), do: files

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
