defmodule JustBash.Commands.Mkdir do
  @moduledoc "The `mkdir` command - make directories."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["mkdir"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, paths} = parse_flags(args)

    {stderr, exit_code, new_fs} =
      Enum.reduce(paths, {"", 0, bash.fs}, fn path, {err_acc, code_acc, fs_acc} ->
        resolved = FS.resolve_path(bash.cwd, path)

        case FS.mkdir(fs_acc, resolved, parents: flags.p) do
          {:ok, new_fs} ->
            {err_acc, code_acc, new_fs}

          {:error, %VFS.Error{kind: :eexist}} when flags.p ->
            handle_existing_path(fs_acc, resolved, path, err_acc, code_acc)

          {:error, %VFS.Error{} = error} ->
            {err_acc <> "mkdir: cannot create directory '#{path}': #{FS.strerror(error)}\n", 1,
             fs_acc}
        end
      end)

    {Command.result("", stderr, exit_code), %{bash | fs: new_fs}}
  end

  # `mkdir -p` is only satisfied by an existing *directory*. A regular file
  # at the path is still an error (bash: "mkdir: PATH: File exists"), and
  # swallowing it would report success for a directory that does not exist.
  defp handle_existing_path(fs, resolved, path, err_acc, code_acc) do
    case FS.stat(fs, resolved) do
      {:ok, %VFS.Stat{type: :directory}, new_fs} ->
        {err_acc, code_acc, new_fs}

      {:ok, _stat, new_fs} ->
        {err_acc <> "mkdir: cannot create directory '#{path}': File exists\n", 1, new_fs}

      {:error, %VFS.Error{} = error} ->
        {err_acc <> "mkdir: cannot create directory '#{path}': #{FS.strerror(error)}\n", 1, fs}
    end
  end

  defp parse_flags(args), do: parse_flags(args, %{p: false}, [])

  defp parse_flags(["-p" | rest], flags, paths),
    do: parse_flags(rest, %{flags | p: true}, paths)

  defp parse_flags([arg | rest], flags, paths),
    do: parse_flags(rest, flags, paths ++ [arg])

  defp parse_flags([], flags, paths), do: {flags, paths}
end
