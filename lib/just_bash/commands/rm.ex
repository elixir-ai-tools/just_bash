defmodule JustBash.Commands.Rm do
  @moduledoc "The `rm` command - remove files or directories."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["rm"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, paths} = parse_flags(args)

    {stderr, exit_code, new_fs} =
      Enum.reduce(paths, {"", 0, bash.fs}, fn path, {err_acc, code_acc, fs_acc} ->
        resolved = FS.resolve_path(bash.cwd, path)

        case FS.rm(fs_acc, resolved, recursive: flags.r) do
          {:ok, new_fs} ->
            {err_acc, code_acc, new_fs}

          {:error, %VFS.Error{kind: :enoent}} when flags.f ->
            {err_acc, code_acc, fs_acc}

          {:error, %VFS.Error{} = error} ->
            {err_acc <> "rm: cannot remove '#{path}': #{FS.strerror(error)}\n", 1, fs_acc}
        end
      end)

    {Command.result("", stderr, exit_code), %{bash | fs: new_fs}}
  end

  defp parse_flags(args) do
    {option_args, extra} = StdinOperand.split_end_of_options(args)
    {flags, paths} = parse_flags(option_args, %{r: false, f: false}, [])
    {flags, paths ++ extra}
  end

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
