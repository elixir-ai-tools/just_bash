defmodule JustBash.Commands.Mkdir do
  @moduledoc "The `mkdir` command - make directories."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
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

          # With -p, the directory GNU reports is the shallowest one it could
          # not create — the offending ancestor — not the whole operand:
          #   mkdir j/2026           -> cannot create directory 'j/2026'
          #   mkdir -p j/2026/deeper -> cannot create directory 'j'
          {:error, %VFS.Error{kind: :enotdir} = error} when flags.p ->
            named = offending_ancestor(fs_acc, bash.cwd, path)
            {err_acc <> failure(named, error), 1, fs_acc}

          {:error, %VFS.Error{} = error} ->
            {err_acc <> failure(path, error), 1, fs_acc}
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

      # `stat` fails on a dangling symlink, but the *name* is taken, so
      # `mkdir` cannot have it — GNU says "File exists". Only a name that is
      # absent in `lstat` too gets the stat error.
      {:error, %VFS.Error{} = error} ->
        case FS.lstat(fs, resolved) do
          {:ok, _stat, new_fs} ->
            {err_acc <> "mkdir: cannot create directory '#{path}': File exists\n", 1, new_fs}

          {:error, %VFS.Error{}} ->
            {err_acc <> failure(path, error), 1, fs}
        end
    end
  end

  # Walk the operand's own components so the name is reported the way the
  # caller wrote it ("j", not "/m/j"), and stop at the first one that exists
  # but is not a directory.
  defp offending_ancestor(fs, cwd, path) do
    trimmed = String.trim_trailing(path, "/")

    trimmed
    |> operand_prefixes()
    |> Enum.find(&non_directory?(fs, FS.resolve_path(cwd, &1)))
    |> Kernel.||(path)
  end

  defp operand_prefixes(path) do
    case String.split(path, "/") do
      ["" | rest] -> rest |> prefixes() |> Enum.map(&("/" <> &1))
      components -> prefixes(components)
    end
  end

  defp prefixes(components) do
    components
    |> Enum.reject(&(&1 == ""))
    |> Enum.scan(&Path.join(&2, &1))
  end

  defp non_directory?(fs, resolved) do
    match?({:ok, %VFS.Stat{type: type}, _fs} when type != :directory, FS.stat(fs, resolved))
  end

  defp failure(path, error) do
    "mkdir: cannot create directory '#{path}': #{FS.strerror(error)}\n"
  end

  defp parse_flags(args) do
    {option_args, extra} = StdinOperand.split_end_of_options(args)
    {flags, paths} = parse_flags(option_args, %{p: false}, [])
    {flags, paths ++ extra}
  end

  defp parse_flags(["-p" | rest], flags, paths),
    do: parse_flags(rest, %{flags | p: true}, paths)

  defp parse_flags([arg | rest], flags, paths),
    do: parse_flags(rest, flags, paths ++ [arg])

  defp parse_flags([], flags, paths), do: {flags, paths}
end
