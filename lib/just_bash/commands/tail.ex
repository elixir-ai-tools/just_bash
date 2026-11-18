defmodule JustBash.Commands.Tail do
  @moduledoc "The `tail` command - output the last part of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FlagParser
  alias JustBash.FS

  @flag_spec %{
    boolean: [],
    # Counts are parsed here, not by FlagParser: `+20` means "from line 20",
    # which an integer cannot say.
    value: [:n, :c],
    defaults: %{n: 10, c: nil},
    usage: "tail [OPTION]... [FILE]..."
  }

  @usage "Try 'tail --help' for more information.\n"

  @impl true
  def names, do: ["tail"]

  @impl true
  def execute(bash, args, stdin) do
    case FlagParser.parse(args, @flag_spec) do
      {:ok, flags, files} ->
        case mode(flags) do
          {:ok, mode} -> tail(bash, mode, files, stdin)
          {:error, message} -> {Command.error(message), bash}
        end

      :help ->
        {Command.ok(FlagParser.help("tail", @flag_spec)), bash}

      {:error, reason} ->
        {Command.error(FlagParser.format_error("tail", reason, @usage)), bash}
    end
  end

  # `{:bytes | :lines, {:last, n} | {:from, n}}`. A count with a leading `+`
  # starts at that line or byte, counting from 1 (`+0` is the same as `+1`);
  # any other count is how many to keep from the end.
  defp mode(%{c: nil, n: n}),
    do: with({:ok, count} <- count(n, "lines"), do: {:ok, {:lines, count}})

  defp mode(%{c: c}), do: with({:ok, count} <- count(c, "bytes"), do: {:ok, {:bytes, count}})

  defp count(n, _unit) when is_integer(n), do: {:ok, {:last, abs(n)}}

  defp count("+" <> digits = raw, unit) do
    case Integer.parse(digits) do
      {n, ""} when n >= 0 -> {:ok, {:from, max(n, 1)}}
      _ -> invalid(raw, unit)
    end
  end

  defp count(raw, unit) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, {:last, abs(n)}}
      _ -> invalid(raw, unit)
    end
  end

  defp invalid(raw, unit), do: {:error, "tail: invalid number of #{unit}: '#{raw}'\n"}

  defp tail(bash, mode, files, stdin) do
    case files do
      [] -> tail_stdin(bash, stdin, mode)
      [file] -> tail_file(bash, file, stdin, mode)
      multiple -> tail_multiple(bash, multiple, stdin, mode)
    end
  end

  defp tail_multiple(bash, files, stdin, mode) do
    {outputs, errors, exit_code, fs} =
      Enum.reduce(files, {[], [], 0, bash.fs}, fn file, {out_acc, err_acc, code, fs} ->
        case StdinOperand.read(fs, bash.cwd, file, stdin) do
          {:ok, content, fs} ->
            header = "==> #{display_name(file)} <==\n"
            body = take_content(content, mode)
            {[header <> body | out_acc], err_acc, code, fs}

          {:error, error} ->
            {out_acc, [read_error(file, error) | err_acc], 1, fs}
        end
      end)

    stdout = outputs |> Enum.reverse() |> Enum.join("\n")
    stderr = errors |> Enum.reverse() |> Enum.join()

    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, %{bash | fs: fs}}
  end

  defp tail_file(bash, file, stdin, mode) do
    case StdinOperand.read(bash.fs, bash.cwd, file, stdin) do
      {:ok, content, fs} ->
        output = take_content(content, mode)
        {Command.ok(output), %{bash | fs: fs}}

      {:error, error} ->
        {Command.error(read_error(file, error)), bash}
    end
  end

  # GNU labels the `-` operand "standard input" in the multi-file header.
  defp display_name(file) do
    if StdinOperand.stdin?(file), do: "standard input", else: file
  end

  # GNU tail `open(2)`s a directory successfully and only fails at `read(2)`,
  # so EISDIR gets a template of its own rather than the open-failure one.
  defp read_error(file, %VFS.Error{kind: :eisdir} = error),
    do: "tail: error reading '#{file}': #{FS.strerror(error)}\n"

  defp read_error(file, error),
    do: "tail: cannot open '#{file}' for reading: #{FS.strerror(error)}\n"

  defp tail_stdin(bash, stdin, mode) do
    output = take_content(stdin, mode)
    {Command.ok(output), bash}
  end

  defp take_content(content, {:bytes, {:last, n}}) do
    size = byte_size(content)
    binary_part(content, size - min(n, size), min(n, size))
  end

  defp take_content(content, {:bytes, {:from, n}}) do
    size = byte_size(content)
    binary_part(content, min(n - 1, size), size - min(n - 1, size))
  end

  defp take_content(content, {:lines, {:last, n}}),
    do: content |> lines() |> Enum.take(-n) |> Enum.join()

  defp take_content(content, {:lines, {:from, n}}),
    do: content |> lines() |> Enum.drop(n - 1) |> Enum.join()

  # Each line with its newline, the last one without if the input does not end
  # in one. Blank lines at either end are lines like any other.
  defp lines(content) do
    content
    |> String.split(~r/(?<=\n)/)
    |> Enum.reject(&(&1 == ""))
  end
end
