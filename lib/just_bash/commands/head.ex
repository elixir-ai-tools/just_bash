defmodule JustBash.Commands.Head do
  @moduledoc "The `head` command - output the first part of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FlagParser
  alias JustBash.FS

  @flag_spec %{
    boolean: [],
    value: [:n, :c],
    integer: [:n, :c],
    value_labels: %{n: "number of lines", c: "number of bytes"},
    defaults: %{n: 10, c: nil},
    usage: "head [OPTION]... [FILE]..."
  }

  @usage "Try 'head --help' for more information.\n"

  @impl true
  def names, do: ["head"]

  @impl true
  def execute(bash, args, stdin) do
    case FlagParser.parse(args, @flag_spec) do
      {:ok, flags, files} -> head(bash, flags, files, stdin)
      :help -> {Command.ok(FlagParser.help("head", @flag_spec)), bash}
      {:error, reason} -> {Command.error(FlagParser.format_error("head", reason, @usage)), bash}
    end
  end

  defp head(bash, flags, files, stdin) do
    mode =
      if flags.c do
        {:bytes, flags.c}
      else
        {:lines, flags.n}
      end

    case files do
      [] -> head_stdin(bash, stdin, mode)
      [file] -> head_file(bash, file, stdin, mode)
      multiple -> head_multiple(bash, multiple, stdin, mode)
    end
  end

  defp head_multiple(bash, files, stdin, mode) do
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

  defp head_file(bash, file, stdin, mode) do
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

  # GNU head `open(2)`s a directory successfully and only fails at `read(2)`,
  # so EISDIR gets a template of its own rather than the open-failure one.
  defp read_error(file, %VFS.Error{kind: :eisdir} = error),
    do: "head: error reading '#{file}': #{FS.strerror(error)}\n"

  defp read_error(file, error),
    do: "head: cannot open '#{file}' for reading: #{FS.strerror(error)}\n"

  defp head_stdin(bash, stdin, mode) do
    output = take_content(stdin, mode)
    {Command.ok(output), bash}
  end

  defp take_content(content, {:bytes, n}) do
    binary_part(content, 0, min(n, byte_size(content)))
  end

  defp take_content(content, {:lines, n}) do
    format_head_output(content, n)
  end

  # GNU head prints through the nth newline, or the whole file when there
  # aren't that many. String.split/2 leaves an empty piece after a
  # terminating newline; taking it and then appending "\n" again was the
  # extra blank line on the default count (and any -n larger than the file).
  defp format_head_output(_content, n) when n <= 0, do: ""

  defp format_head_output(content, n) do
    case content |> :binary.matches("\n") |> Enum.at(n - 1) do
      {offset, 1} -> binary_part(content, 0, offset + 1)
      nil -> content
    end
  end
end
