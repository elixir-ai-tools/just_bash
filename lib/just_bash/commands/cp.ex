defmodule JustBash.Commands.Cp do
  @moduledoc """
  The `cp` command - copy files and directory trees.

  Flags: `-r`/`-R`/`--recursive` and `-a`/`--archive` (which implies
  `--recursive`) copy directories. `-f`/`--force` and `-p`/`--preserve`
  are accepted and do nothing: a copy always overwrites its destination,
  and always carries the source's mode and mtime across.

  As in bash, a destination that is an existing directory receives the
  source under its own basename, and any number of sources may be copied
  into a trailing directory operand.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.FS

  # `-R` and the long forms are aliases of `-r`; FlagParser sees `--recursive`
  # as the flag string "-recursive".
  @flag_spec %{
    boolean: [:r, :a, :f, :p],
    aliases: %{
      "R" => :r,
      "-recursive" => :r,
      "-archive" => :a,
      "-force" => :f,
      "-preserve" => :p
    },
    value: [],
    defaults: %{r: false, a: false, f: false, p: false}
  }

  @try_help "Try 'cp --help' for more information.\n"

  @impl true
  def names, do: ["cp"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, operands} = FlagParser.parse(args, @flag_spec)
    copy(bash, operands, flags.r or flags.a)
  end

  defp copy(bash, [], _recursive?),
    do: {Command.error("cp: missing file operand\n" <> @try_help), bash}

  defp copy(bash, [src], _recursive?),
    do:
      {Command.error("cp: missing destination file operand after '#{src}'\n" <> @try_help), bash}

  # Two operands: the destination names the copy, unless it already exists as a
  # directory — then the copy lands inside it under the source's basename.
  defp copy(bash, [src, dest], recursive?) do
    case dest_kind(bash, dest) do
      {:directory, bash} -> copy_one(bash, src, dest_in_dir(dest, src), recursive?)
      {_kind, bash} -> copy_one(bash, src, dest, recursive?)
    end
  end

  # Three or more operands: the last one has to be an existing directory.
  defp copy(bash, operands, recursive?) do
    {sources, [dest]} = Enum.split(operands, -1)

    case dest_kind(bash, dest) do
      {:directory, bash} ->
        copy_each(bash, sources, dest, recursive?)

      {{:error, error}, bash} ->
        {Command.error("cp: target '#{dest}': #{FS.strerror(error)}\n"), bash}

      {_kind, bash} ->
        {Command.error("cp: target '#{dest}': Not a directory\n"), bash}
    end
  end

  defp dest_kind(bash, dest) do
    case FS.stat(bash.fs, FS.resolve_path(bash.cwd, dest)) do
      {:ok, %VFS.Stat{type: :directory}, fs} -> {:directory, %{bash | fs: fs}}
      {:ok, %VFS.Stat{}, fs} -> {:other, %{bash | fs: fs}}
      {:error, %VFS.Error{} = error} -> {{:error, error}, bash}
    end
  end

  # A failing source does not abort the run: bash copies what it can, reports
  # every failure, and exits 1.
  defp copy_each(bash, sources, dest, recursive?) do
    {stderr, exit_code, bash} =
      Enum.reduce(sources, {[], 0, bash}, fn src, {err_acc, code_acc, bash_acc} ->
        {result, bash_acc} = copy_one(bash_acc, src, dest_in_dir(dest, src), recursive?)
        {[err_acc, result.stderr], max(code_acc, result.exit_code), bash_acc}
      end)

    {Command.result("", IO.iodata_to_binary(stderr), exit_code), bash}
  end

  defp copy_one(bash, src, dest, recursive?) do
    src_path = FS.resolve_path(bash.cwd, src)
    dest_path = FS.resolve_path(bash.cwd, dest)

    if src_path == dest_path do
      {Command.error("cp: '#{src}' and '#{dest}' are the same file\n"), bash}
    else
      copy_resolved(bash, {src, src_path}, {dest, dest_path}, recursive?)
    end
  end

  defp copy_resolved(bash, {src, src_path}, {dest, dest_path}, recursive?) do
    case FS.lstat(bash.fs, src_path) do
      {:ok, %VFS.Stat{type: :directory}, fs} ->
        copy_dir(%{bash | fs: fs}, {src, src_path}, {dest, dest_path}, recursive?)

      # Without `-d`/`-P`, bash copies what a link points at, not the link.
      {:ok, %VFS.Stat{type: :symlink}, fs} ->
        copy_dereferenced(%{bash | fs: fs}, {src, src_path}, {dest, dest_path})

      {:ok, %VFS.Stat{}, fs} ->
        fs
        |> FS.cp(src_path, dest_path)
        |> file_result(%{bash | fs: fs}, dest)

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot stat '#{src}': #{FS.strerror(error)}\n"), bash}
    end
  end

  defp copy_dir(bash, {src, _src_path}, {_dest, _dest_path}, false),
    do: {Command.error("cp: -r not specified; omitting directory '#{src}'\n"), bash}

  defp copy_dir(bash, {src, src_path}, {dest, dest_path}, true) do
    case FS.cp(bash.fs, src_path, dest_path, recursive: true) do
      {:ok, fs} ->
        {Command.ok(), %{bash | fs: fs}}

      {:error, %VFS.Error{kind: :einval}} ->
        {Command.error("cp: cannot copy a directory, '#{src}', into itself, '#{dest}'\n"), bash}

      {:error, %VFS.Error{kind: :enotdir}} ->
        {Command.error("cp: cannot overwrite non-directory '#{dest}' with directory '#{src}'\n"),
         bash}

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot create directory '#{dest}': #{FS.strerror(error)}\n"), bash}
    end
  end

  defp copy_dereferenced(bash, {src, src_path}, {dest, dest_path}) do
    case FS.read_file(bash.fs, src_path) do
      {:ok, content, fs} ->
        fs
        |> FS.write_file(dest_path, content)
        |> file_result(%{bash | fs: fs}, dest)

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot stat '#{src}': #{FS.strerror(error)}\n"), bash}
    end
  end

  defp file_result({:ok, fs}, bash, _dest), do: {Command.ok(), %{bash | fs: fs}}

  defp file_result({:error, %VFS.Error{kind: :eisdir}}, bash, dest),
    do: {Command.error("cp: cannot overwrite directory '#{dest}' with non-directory\n"), bash}

  # GNU stats the destination before opening it, so a path component that is a
  # regular file surfaces as `cannot stat`. `cannot create regular file` stays
  # the wording for a destination whose parent is merely missing.
  defp file_result({:error, %VFS.Error{kind: :enotdir} = error}, bash, dest),
    do: {Command.error("cp: cannot stat '#{dest}': #{FS.strerror(error)}\n"), bash}

  defp file_result({:error, %VFS.Error{} = error}, bash, dest),
    do: {Command.error("cp: cannot create regular file '#{dest}': #{FS.strerror(error)}\n"), bash}

  # The destination of a copy into a directory, spelled the way bash spells it
  # in messages: the directory operand with the source's basename appended. The
  # `dir/.` idiom copies the source's *contents*, so it keeps the destination.
  defp dest_in_dir(dest, src) do
    if dot_segment?(src) do
      dest
    else
      String.trim_trailing(dest, "/") <> "/" <> FS.basename(src)
    end
  end

  defp dot_segment?(src), do: List.last(String.split(src, "/")) in [".", ".."]
end
