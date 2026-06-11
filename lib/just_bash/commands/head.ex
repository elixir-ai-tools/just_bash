defmodule JustBash.Commands.Head do
  @moduledoc "The `head` command - output the first part of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs

  @flag_spec %{
    boolean: [],
    value: [:n, :c],
    defaults: %{n: 10, c: nil}
  }

  @impl true
  def names, do: ["head"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = FlagParser.parse(args, @flag_spec)

    mode =
      if flags.c do
        {:bytes, flags.c}
      else
        {:lines, flags.n}
      end

    case files do
      [] -> head_stdin(bash, stdin, mode)
      [file] -> head_file(bash, file, mode)
      multiple -> head_multiple(bash, multiple, mode)
    end
  end

  defp head_multiple(bash, files, mode) do
    {outputs, errors, exit_code} =
      Enum.reduce(files, {[], [], 0}, fn file, {out_acc, err_acc, code} ->
        resolved = Fs.resolve_path(bash.cwd, file)

        case Fs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            header = "==> #{file} <==\n"
            body = take_content(content, mode)
            {[header <> body | out_acc], err_acc, code}

          {:error, _} ->
            err = "head: cannot open '#{file}' for reading: No such file or directory\n"
            {out_acc, [err | err_acc], 1}
        end
      end)

    stdout = outputs |> Enum.reverse() |> Enum.join("\n")
    stderr = errors |> Enum.reverse() |> Enum.join()

    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, bash}
  end

  defp head_file(bash, file, mode) do
    resolved = Fs.resolve_path(bash.cwd, file)

    case Fs.read_file(bash.fs, resolved) do
      {:ok, content} ->
        output = take_content(content, mode)
        {Command.ok(output), bash}

      {:error, _} ->
        {Command.error("head: cannot open '#{file}' for reading: No such file or directory\n"),
         bash}
    end
  end

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

  defp format_head_output(content, n) do
    lines = String.split(content, "\n")
    output = lines |> Enum.take(n) |> Enum.join("\n")

    if String.ends_with?(content, "\n") or length(lines) <= n,
      do: output <> "\n",
      else: output
  end
end
