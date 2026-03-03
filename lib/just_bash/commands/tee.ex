defmodule JustBash.Commands.Tee do
  @moduledoc "The `tee` command - read from stdin and write to stdout and files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["tee"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        {new_bash, stderr, exit_code} =
          write_files(bash, opts.files, stdin, opts.append)

        result = %{
          stdout: stdin,
          stderr: stderr,
          exit_code: exit_code
        }

        {result, new_bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{append: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-a" | rest], opts) do
    parse_args(rest, %{opts | append: true})
  end

  defp parse_args(["--append" | rest], opts) do
    parse_args(rest, %{opts | append: true})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "tee: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp write_files(bash, files, content, append) do
    Enum.reduce(files, {bash, "", 0}, fn file, {acc_bash, acc_stderr, acc_code} ->
      # /dev/null is a black hole - just ignore writes to it
      if file == "/dev/null" do
        {acc_bash, acc_stderr, acc_code}
      else
        resolved = InMemoryFs.resolve_path(acc_bash.cwd, file)
        write_single_file(acc_bash, resolved, file, content, append, acc_stderr, acc_code)
      end
    end)
  end

  defp write_single_file(bash, resolved, file, content, append, acc_stderr, acc_code) do
    parent = Path.dirname(resolved)

    case InMemoryFs.stat(bash.fs, parent) do
      {:ok, %{is_directory: true}} ->
        do_write_file(bash, resolved, file, content, append, acc_stderr, acc_code)

      _ ->
        {bash, acc_stderr <> "tee: #{file}: No such file or directory\n", 1}
    end
  end

  defp do_write_file(bash, resolved, file, content, append, acc_stderr, acc_code) do
    result = write_or_append(bash, resolved, content, append)

    case result do
      {:ok, new_bash} -> {new_bash, acc_stderr, acc_code}
      {:error, _} -> {bash, acc_stderr <> "tee: #{file}: Is a directory\n", 1}
    end
  end

  defp write_or_append(bash, resolved, content, true) do
    InMemoryFs.append_file(bash, resolved, content)
  end

  defp write_or_append(bash, resolved, content, false) do
    case InMemoryFs.write_file(bash.fs, resolved, content) do
      {:ok, new_fs} -> {:ok, %{bash | fs: new_fs}}
      error -> error
    end
  end
end
