defmodule JustBash.Commands.Readlink do
  @moduledoc "The `readlink` command - print resolved symbolic links."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["readlink"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        execute_readlink(bash, opts)
    end
  end

  defp execute_readlink(bash, %{files: []}) do
    {Command.error("readlink: missing operand\n"), bash}
  end

  defp execute_readlink(bash, opts) do
    {output, any_error} =
      Enum.reduce(opts.files, {"", false}, fn file, acc ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)
        result = process_file(bash.fs, resolved, file, opts.canonicalize)
        accumulate_readlink_result(result, acc)
      end)

    exit_code = if any_error, do: 1, else: 0
    {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
  end

  defp accumulate_readlink_result({:ok, path}, {acc_out, acc_err}) do
    {acc_out <> path <> "\n", acc_err}
  end

  defp accumulate_readlink_result({:error, _}, {acc_out, _acc_err}) do
    {acc_out, true}
  end

  defp parse_args(args) do
    parse_args(args, %{canonicalize: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-f" | rest], opts) do
    parse_args(rest, %{opts | canonicalize: true})
  end

  defp parse_args(["--canonicalize" | rest], opts) do
    parse_args(rest, %{opts | canonicalize: true})
  end

  defp parse_args(["--" | rest], opts) do
    {:ok, %{opts | files: opts.files ++ rest}}
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "readlink: invalid option -- '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp process_file(fs, path, _original, false) do
    case InMemoryFs.readlink(fs, path) do
      {:ok, target} -> {:ok, target}
      {:error, _} -> {:error, :not_symlink}
    end
  end

  defp process_file(fs, path, _original, true) do
    resolve_path(fs, path, MapSet.new())
  end

  defp resolve_path(fs, path, seen) do
    if MapSet.member?(seen, path) do
      {:ok, path}
    else
      resolve_path_uncached(fs, path, seen)
    end
  end

  defp resolve_path_uncached(fs, path, seen) do
    case InMemoryFs.readlink(fs, path) do
      {:ok, target} ->
        new_path = resolve_target(path, target)
        resolve_path(fs, new_path, MapSet.put(seen, path))

      {:error, _} ->
        {:ok, path}
    end
  end

  defp resolve_target(_path, "/" <> _ = target), do: target

  defp resolve_target(path, target) do
    dir = Path.dirname(path)
    InMemoryFs.resolve_path(dir, target)
  end
end
