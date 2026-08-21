defmodule JustBash.Commands.Mv do
  @moduledoc "The `mv` command - move (rename) files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["mv"]

  @impl true
  def execute(bash, args, _stdin) do
    case StdinOperand.drop_end_of_options(args) do
      [src, dest] -> move(bash, src, dest)
      _ -> {Command.error("mv: missing file operand\n"), bash}
    end
  end

  defp move(bash, src, dest) do
    src_resolved = FS.resolve_path(bash.cwd, src)
    dest_resolved = FS.resolve_path(bash.cwd, dest)

    # `dest_final` is where the move lands; `dest_shown` is the same place
    # spelled the way the operand was, which is how bash names it in
    # messages ("a/b/a", not "/tmp/x/a/b/a").
    {dest_final, dest_shown, fs} = destination(bash.fs, src_resolved, dest, dest_resolved)
    bash = %{bash | fs: fs}

    # bash stats the source, then the destination, and only then asks whether
    # the two name the same file — so a missing source is reported ahead of
    # anything the destination is wrong about, and a destination whose
    # spelling does not hold is reported ahead of the comparison it would
    # otherwise take part in.
    with {:ok, src_type} <- source_type(bash, src, src_resolved),
         :ok <- destination_directory(bash, {src, src_type}, dest),
         :ok <- distinct(src_resolved, dest_final) do
      rename(bash, {src, src_resolved}, {dest, dest_shown, dest_final})
    else
      {:error, message} -> {Command.error(message), bash}
    end
  end

  # A destination that already exists as a directory receives the source under
  # its own basename; anything else is the name the move lands under.
  defp destination(fs, {:error, :enoent}, dest, dest_resolved), do: {dest_resolved, dest, fs}

  defp destination(fs, _src_resolved, dest, {:error, :enoent} = dest_resolved),
    do: {dest_resolved, dest, fs}

  defp destination(fs, src_resolved, dest, dest_resolved) do
    case FS.stat(fs, dest_resolved) do
      {:ok, %VFS.Stat{type: :directory}, fs} ->
        basename = FS.basename(src_resolved)

        {FS.normalize_path(dest_resolved <> "/" <> basename),
         String.trim_trailing(dest, "/") <> "/" <> basename, fs}

      {:ok, _stat, fs} ->
        {dest_resolved, dest, fs}

      {:error, _} ->
        {dest_resolved, dest, fs}
    end
  end

  # Once the destination's spelling has been held to its promise, a
  # destination that lands back on the source *is* the source, however it was
  # spelled: `d/`, `d/.` and `d/../d/` all name the directory the source
  # already sits in. Checked against GNU coreutils 9.11:
  #
  #     $ mv d/keep d/   mv: 'd/keep' and 'd/keep' are the same file
  #
  # (`a.md/` never reaches here — `destination_directory/3` reports it, which
  # is why this asks nothing about the spelling.)
  defp distinct(src_resolved, dest_final)
       when is_binary(src_resolved) and is_binary(dest_final) do
    if FS.normalize_path(src_resolved) == FS.normalize_path(dest_final) do
      {:error, "mv: '#{src_resolved}' and '#{dest_final}' are the same file\n"}
    else
      :ok
    end
  end

  defp distinct(_src_resolved, _dest_final), do: :ok

  defp source_type(bash, src, src_resolved) do
    case FS.lstat(bash.fs, src_resolved) do
      {:ok, %VFS.Stat{type: type}, _fs} ->
        {:ok, type}

      {:error, %VFS.Error{} = error} ->
        {:error, "mv: cannot stat '#{src}': #{FS.strerror(error)}\n"}
    end
  end

  # POSIX reads the trailing slash in `mv a.md f/` as an assertion that `f` is
  # a directory, and `resolve_path/2` normalizes it away. Only a directory
  # arriving at a destination that does not exist yet makes the assertion true
  # by itself. Wording checked against GNU coreutils 9.11:
  #
  #     $ mv a.md f/     mv: cannot stat 'f/': Not a directory
  #     $ mv a.md nope/  mv: cannot move 'a.md' to 'nope/': No such file …
  #     $ mv src nope/   (renames the directory)
  defp destination_directory(bash, {src, src_type}, dest) do
    case FS.check_directory_spelling(bash.fs, bash.cwd, dest) do
      {:ok, _fs} -> :ok
      {:error, %VFS.Error{kind: :enoent}} when src_type == :directory and dest != "" -> :ok
      {:error, %VFS.Error{} = error} -> {:error, dest_error(src, dest, error)}
    end
  end

  defp dest_error(_src, dest, %VFS.Error{kind: :enotdir} = error),
    do: "mv: cannot stat '#{dest}': #{FS.strerror(error)}\n"

  defp dest_error(src, dest, %VFS.Error{} = error),
    do: "mv: cannot move '#{src}' to '#{dest}': #{FS.strerror(error)}\n"

  defp rename(bash, {src, src_resolved}, {dest, dest_shown, dest_final}) do
    case FS.mv(bash.fs, src_resolved, dest_final) do
      {:ok, new_fs} ->
        {Command.ok(), %{bash | fs: new_fs}}

      {:error, %VFS.Error{kind: :enoent}} ->
        {Command.error("mv: cannot stat '#{src}': #{FS.strerror(:enoent)}\n"), bash}

      {:error, %VFS.Error{kind: :eisdir}} ->
        {Command.error("mv: cannot overwrite directory '#{dest}' with non-directory\n"), bash}

      {:error, %VFS.Error{kind: :einval}} ->
        {Command.error("mv: cannot move '#{src}' to a subdirectory of itself, '#{dest_shown}'\n"),
         bash}

      # :enotdir needs no clause of its own — the catch-all below already
      # spells it "cannot move 'src' to 'dest': Not a directory", which is
      # why #56 removed the explicit one.
      {:error, %VFS.Error{} = error} ->
        {Command.error("mv: cannot move '#{src}' to '#{dest}': #{FS.strerror(error)}\n"), bash}
    end
  end
end
