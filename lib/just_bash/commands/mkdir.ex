defmodule JustBash.Commands.Mkdir do
  @moduledoc "The `mkdir` command - make directories."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["mkdir"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, paths} = parse_flags(args)

    {stderr, exit_code, new_fs} =
      Enum.reduce(paths, {"", 0, bash.fs}, fn path, {err_acc, code_acc, fs_acc} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, path)

        case InMemoryFs.mkdir(fs_acc, resolved, recursive: flags.p) do
          {:ok, new_fs} ->
            {err_acc, code_acc, new_fs}

          {:error, :eexist} when flags.p ->
            {err_acc, code_acc, fs_acc}

          {:error, :eexist} ->
            {err_acc <> "mkdir: cannot create directory '#{path}': File exists\n", 1, fs_acc}

          {:error, :enoent} ->
            {err_acc <> "mkdir: cannot create directory '#{path}': No such file or directory\n",
             1, fs_acc}
        end
      end)

    {Command.result("", stderr, exit_code), %{bash | fs: new_fs}}
  end

  defp parse_flags(args), do: parse_flags(args, %{p: false}, [])

  defp parse_flags(["-p" | rest], flags, paths),
    do: parse_flags(rest, %{flags | p: true}, paths)

  defp parse_flags([arg | rest], flags, paths),
    do: parse_flags(rest, flags, paths ++ [arg])

  defp parse_flags([], flags, paths), do: {flags, paths}
end
