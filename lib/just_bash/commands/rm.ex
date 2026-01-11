defmodule JustBash.Commands.Rm do
  @moduledoc "The `rm` command - remove files or directories."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["rm"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, paths} = parse_flags(args)

    {stderr, exit_code, new_fs} =
      Enum.reduce(paths, {"", 0, bash.fs}, fn path, {err_acc, code_acc, fs_acc} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, path)

        case InMemoryFs.rm(fs_acc, resolved, recursive: flags.r, force: flags.f) do
          {:ok, new_fs} ->
            {err_acc, code_acc, new_fs}

          {:error, :enoent} when flags.f ->
            {err_acc, code_acc, fs_acc}

          {:error, :enoent} ->
            {err_acc <> "rm: cannot remove '#{path}': No such file or directory\n", 1, fs_acc}

          {:error, :enotempty} ->
            {err_acc <> "rm: cannot remove '#{path}': Directory not empty\n", 1, fs_acc}
        end
      end)

    {Command.result("", stderr, exit_code), %{bash | fs: new_fs}}
  end

  defp parse_flags(args), do: parse_flags(args, %{r: false, f: false}, [])

  defp parse_flags(["-r" | rest], flags, paths),
    do: parse_flags(rest, %{flags | r: true}, paths)

  defp parse_flags(["-f" | rest], flags, paths),
    do: parse_flags(rest, %{flags | f: true}, paths)

  defp parse_flags(["-rf" | rest], flags, paths),
    do: parse_flags(rest, %{flags | r: true, f: true}, paths)

  defp parse_flags(["-fr" | rest], flags, paths),
    do: parse_flags(rest, %{flags | r: true, f: true}, paths)

  defp parse_flags([arg | rest], flags, paths), do: parse_flags(rest, flags, paths ++ [arg])
  defp parse_flags([], flags, paths), do: {flags, paths}
end
