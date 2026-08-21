defmodule JustBash.Commands.Realpath do
  @moduledoc """
  The `realpath` command - print the resolved absolute path.

  Resolves `.`, `..`, and symlinks in the virtual filesystem.

  How much of the path has to exist depends on the mode, as in GNU realpath:

    * default — every component *but the last* must resolve to a directory,
      so `realpath /nope` canonicalises and exits 0 while
      `realpath /nope/deep/x` does not
    * `-e` — the whole path must exist
    * `-m` — nothing has to exist
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["realpath"]

  @impl true
  def execute(bash, args, _stdin) do
    {opts, paths} = parse_args(args)

    case paths do
      [] ->
        {Command.error("realpath: missing operand\n"), bash}

      _ ->
        {out_parts, err_parts, exit_code, fs} =
          Enum.reduce(paths, {[], [], 0, bash.fs}, fn path, {out, err, code, fs} ->
            resolved = FS.resolve_path(bash.cwd, path)

            case check(fs, resolved, opts.mode) do
              {:ok, fs} ->
                {[out, resolved, "\n"], err, code, fs}

              {:error, error, fs} ->
                {out, [err, "realpath: ", path, ": ", FS.strerror(error), "\n"], 1, fs}
            end
          end)

        {Command.result(
           IO.iodata_to_binary(out_parts),
           IO.iodata_to_binary(err_parts),
           exit_code
         ), %{bash | fs: fs}}
    end
  end

  defp check(fs, {:error, %VFS.Error{} = error}, _mode), do: {:error, error, fs}

  defp check(fs, _resolved, :missing), do: {:ok, fs}

  defp check(fs, resolved, :existing) do
    case FS.stat(fs, resolved) do
      {:ok, _stat, fs} -> {:ok, fs}
      {:error, error} -> {:error, error, fs}
    end
  end

  # The default mode names the operand in its diagnostic but only requires the
  # parent to be a directory: `realpath /f/x` on a regular-file `/f` is ENOTDIR
  # even though `/f` itself stats cleanly.
  defp check(fs, resolved, :default) do
    case FS.stat(fs, Path.dirname(resolved)) do
      {:ok, %VFS.Stat{type: :directory}, fs} -> {:ok, fs}
      {:ok, _not_a_directory, fs} -> {:error, :enotdir, fs}
      {:error, error} -> {:error, error, fs}
    end
  end

  defp parse_args(args) do
    {option_args, extra} = StdinOperand.split_end_of_options(args)
    {opts, paths} = parse_args(option_args, %{mode: :default}, [])
    {opts, paths ++ extra}
  end

  defp parse_args([], opts, paths), do: {opts, Enum.reverse(paths)}

  defp parse_args([flag | rest], opts, paths)
       when flag in ["-e", "--canonicalize-existing"],
       do: parse_args(rest, %{opts | mode: :existing}, paths)

  defp parse_args([flag | rest], opts, paths)
       when flag in ["-m", "--canonicalize-missing"],
       do: parse_args(rest, %{opts | mode: :missing}, paths)

  # Skip the flags we do not model yet: -s, --relative-to, …
  defp parse_args(["--" <> _ | rest], opts, paths), do: parse_args(rest, opts, paths)

  defp parse_args(["-" <> _ | rest], opts, paths),
    do: parse_args(rest, opts, paths)

  defp parse_args([path | rest], opts, paths), do: parse_args(rest, opts, [path | paths])
end
