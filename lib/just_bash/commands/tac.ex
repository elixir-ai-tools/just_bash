defmodule JustBash.Commands.Tac do
  @moduledoc "The `tac` command - concatenate and print files in reverse."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["tac"]

  @impl true
  def execute(bash, args, stdin) do
    case read_operands(bash, StdinOperand.operands(args), stdin) do
      {:error, msg} -> {Command.error(msg), bash}
      {:ok, output, fs} -> {Command.ok(output), %{bash | fs: fs}}
    end
  end

  # `tac a b` is `tac a; tac b`: GNU reverses each operand's lines on its own
  # and writes the operands in the order given, so it is not `cat a b | tac`,
  # which would also reverse the operands against each other.
  defp read_operands(bash, files, stdin) do
    files
    |> defaults_to_stdin()
    |> Enum.reduce_while({:ok, [], bash.fs}, fn file, {:ok, acc, fs} ->
      case StdinOperand.read(fs, bash.cwd, file, stdin) do
        {:ok, data, fs} -> {:cont, {:ok, [reverse_records(data) | acc], fs}}
        {:error, error} -> {:halt, {:error, read_error(file, error)}}
      end
    end)
    |> collect()
  end

  defp defaults_to_stdin([]), do: ["-"]
  defp defaults_to_stdin(files), do: files

  defp collect({:ok, reversed, fs}),
    do: {:ok, reversed |> Enum.reverse() |> IO.iodata_to_binary(), fs}

  defp collect({:error, _msg} = error), do: error

  # GNU tac `open(2)`s a directory successfully and only fails at `read(2)`,
  # so EISDIR gets a template of its own rather than the open-failure one.
  defp read_error(file, %VFS.Error{kind: :eisdir} = error),
    do: "tac: #{file}: read error: #{FS.strerror(error)}\n"

  defp read_error(file, error),
    do: "tac: failed to open '#{file}' for reading: #{FS.strerror(error)}\n"

  # GNU tac reverses records, not newline-split lines. A record is the text
  # up to and including its separator; an unterminated last record carries
  # none. Split-and-rejoin manufactured a separator `"1\n2"` never had.
  defp reverse_records(content) do
    content
    |> records()
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp records(content) do
    content
    |> String.split("\n", trim: false)
    |> attach_separators()
  end

  defp attach_separators([""]), do: []

  defp attach_separators(parts) do
    {last, rest} = List.pop_at(parts, -1)
    rest |> Enum.map(&(&1 <> "\n")) |> attach_last(last)
  end

  defp attach_last(terminated, ""), do: terminated
  defp attach_last(terminated, last) when is_binary(last), do: terminated ++ [last]
end
