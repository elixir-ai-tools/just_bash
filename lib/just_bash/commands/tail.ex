defmodule JustBash.Commands.Tail do
  @moduledoc "The `tail` command - output the last part of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.FS

  @flag_spec %{
    boolean: [],
    value: [:n, :c],
    integer: [:n, :c],
    value_labels: %{n: "number of lines", c: "number of bytes"},
    defaults: %{n: 10, c: nil},
    usage: "tail [OPTION]... [FILE]..."
  }

  @usage "Try 'tail --help' for more information.\n"

  @impl true
  def names, do: ["tail"]

  @impl true
  def execute(bash, args, stdin) do
    case FlagParser.parse(args, @flag_spec) do
      {:ok, flags, files} -> tail(bash, flags, files, stdin)
      :help -> {Command.ok(FlagParser.help("tail", @flag_spec)), bash}
      {:error, reason} -> {Command.error(FlagParser.format_error("tail", reason, @usage)), bash}
    end
  end

  defp tail(bash, flags, files, stdin) do
    mode =
      if flags.c do
        {:bytes, flags.c}
      else
        {:lines, flags.n}
      end

    case files do
      [] -> tail_stdin(bash, stdin, mode)
      [file] -> tail_file(bash, file, mode)
      multiple -> tail_multiple(bash, multiple, mode)
    end
  end

  defp tail_multiple(bash, files, mode) do
    {outputs, errors, exit_code, fs} =
      Enum.reduce(files, {[], [], 0, bash.fs}, fn file, {out_acc, err_acc, code, fs} ->
        resolved = FS.resolve_path(bash.cwd, file)

        case FS.read_file(fs, resolved) do
          {:ok, content, fs} ->
            header = "==> #{file} <==\n"
            body = take_content(content, mode)
            {[header <> body | out_acc], err_acc, code, fs}

          {:error, _} ->
            err = "tail: cannot open '#{file}' for reading: No such file or directory\n"
            {out_acc, [err | err_acc], 1, fs}
        end
      end)

    stdout = outputs |> Enum.reverse() |> Enum.join("\n")
    stderr = errors |> Enum.reverse() |> Enum.join()

    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, %{bash | fs: fs}}
  end

  defp tail_file(bash, file, mode) do
    resolved = FS.resolve_path(bash.cwd, file)

    case FS.read_file(bash.fs, resolved) do
      {:ok, content, fs} ->
        output = take_content(content, mode)
        {Command.ok(output), %{bash | fs: fs}}

      {:error, _} ->
        {Command.error("tail: cannot open '#{file}' for reading: No such file or directory\n"),
         bash}
    end
  end

  defp tail_stdin(bash, stdin, mode) do
    output = take_content(stdin, mode)
    {Command.ok(output), bash}
  end

  defp take_content(content, {:bytes, n}) do
    size = byte_size(content)

    if n >= size do
      content
    else
      binary_part(content, size - n, n)
    end
  end

  defp take_content(content, {:lines, n}) do
    format_tail_output(content, n)
  end

  defp format_tail_output(content, n) do
    lines = String.split(content, "\n", trim: true)
    output = lines |> Enum.take(-n) |> Enum.join("\n")
    if output != "", do: output <> "\n", else: output
  end
end
