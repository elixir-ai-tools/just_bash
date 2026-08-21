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

      {:ok, output, fs} ->
        {Command.ok(output), %{bash | fs: fs}}
    end
  end

  # `rev a b` is `rev a; rev b`, not `cat a b | rev`. Concatenating first
  # glues an unterminated last line of `a` onto the first line of `b` and
  # reverses them as one record.
  defp read_operands(bash, files, stdin) do
    files
    |> defaults_to_stdin()
    |> Enum.reduce_while({:ok, [], bash.fs}, fn file, {:ok, acc, fs} ->
      case StdinOperand.read(fs, bash.cwd, file, stdin) do
        {:ok, data, fs} -> {:cont, {:ok, [reverse_chars_per_line(data) | acc], fs}}
        {:error, error} -> {:halt, {:error, "rev: #{file}: #{FS.strerror(error)}\n"}}
      end
    end)
    |> collect()
  end

  defp defaults_to_stdin([]), do: ["-"]
  defp defaults_to_stdin(files), do: files

  defp collect({:ok, reversed, fs}),
    do: {:ok, reversed |> Enum.reverse() |> IO.iodata_to_binary(), fs}

  defp collect({:error, _msg} = error), do: error

  defp reverse_chars_per_line(content) do
    content
    |> records()
    |> Enum.map(&reverse_record/1)
    |> IO.iodata_to_binary()
  end

  # A record is text up to and including its separator. The last record
  # carries none when the input has no trailing newline, so reversing
  # characters must not manufacture one.
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

  defp reverse_record(record) do
    if String.ends_with?(record, "\n") do
      reverse_string(binary_part(record, 0, byte_size(record) - 1)) <> "\n"
    else
      reverse_string(record)
    end
  end

  defp reverse_string(str) do
    str
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.join()
  end
end
