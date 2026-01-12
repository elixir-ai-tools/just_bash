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
        {new_fs, stderr, exit_code} =
          write_files(bash.fs, bash.cwd, opts.files, stdin, opts.append)

        new_bash = %{bash | fs: new_fs}

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

  defp write_files(fs, cwd, files, content, append) do
    Enum.reduce(files, {fs, "", 0}, fn file, {acc_fs, acc_stderr, acc_code} ->
      resolved = InMemoryFs.resolve_path(cwd, file)
      parent = Path.dirname(resolved)

      case InMemoryFs.stat(acc_fs, parent) do
        {:ok, %{is_directory: true}} ->
          result =
            if append do
              InMemoryFs.append_file(acc_fs, resolved, content)
            else
              InMemoryFs.write_file(acc_fs, resolved, content)
            end

          case result do
            {:ok, new_fs} -> {new_fs, acc_stderr, acc_code}
            {:error, _} -> {acc_fs, acc_stderr <> "tee: #{file}: Is a directory\n", 1}
          end

        _ ->
          {acc_fs, acc_stderr <> "tee: #{file}: No such file or directory\n", 1}
      end
    end)
  end
end
