defmodule JustBash.Commands.Cp do
  @moduledoc """
  The `cp` command - copy files and directory trees.

  Flags:

    * `-r`/`-R`/`--recursive`, and `-a`/`--archive` (which implies
      `--recursive`) — copy directory trees.
    * `-n`/`--no-clobber` — leave an existing destination alone. Bash decides
      this per file inside a tree; here it is decided per operand.
    * `-P`/`--no-dereference` (and `-d`) / `-L`/`--dereference` — copy a
      command-line symlink as a link, or follow it. As in bash, a shallow copy
      follows the link and a recursive copy preserves it; `-L` and `-P`
      override that. Links *inside* a copied tree are always preserved.
    * `-v`/`--verbose` — print `'src' -> 'dest'` for every copied entry.
    * `-f`/`--force`, `-p`/`--preserve` and `-i`/`--interactive` — accepted,
      with nothing to do: a copy always overwrites, always carries the
      source's mode and mtime across, and a sandbox has no terminal to prompt
      on (so `-i` proceeds as if the prompt were answered yes).

  As in bash, a destination that is an existing directory receives the source
  under its own basename, and any number of sources may be copied into a
  trailing directory operand.

  A recursive copy refuses a destination inside the source, including one that
  only reaches it through a symlink (`FS.cp/4` resolves both operands first).
  One wording diverges there: for a destination that does not exist yet, such
  as `cp -r a l/x` with `l -> a`, bash reaches the case through its
  inode-based self-detection mid-walk and reports `will not create hard link`,
  while the path check here gets there first and reports `cannot copy a
  directory, 'a', into itself`. Same exit code, same untouched source.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.FS

  defmodule Options do
    @moduledoc false

    @enforce_keys [:mode, :links, :clobber, :verbose?]
    defstruct [:mode, :links, :clobber, :verbose?]

    @type t :: %__MODULE__{
            mode: :recursive | :shallow,
            links: :follow | :preserve,
            clobber: :always | :never,
            verbose?: boolean()
          }
  end

  # `-R` and the long forms are aliases of their short flags; FlagParser sees
  # `--recursive` as the flag string "-recursive".
  @flag_spec %{
    boolean: [:r, :a, :f, :p, :n, :i, :v, :P, :L, :d],
    aliases: %{
      "R" => :r,
      "-recursive" => :r,
      "-archive" => :a,
      "-force" => :f,
      "-preserve" => :p,
      "-no-clobber" => :n,
      "-interactive" => :i,
      "-verbose" => :v,
      "-no-dereference" => :P,
      "-dereference" => :L
    },
    value: [],
    defaults: %{
      r: false,
      a: false,
      f: false,
      p: false,
      n: false,
      i: false,
      v: false,
      P: false,
      L: false,
      d: false
    }
  }

  @try_help "Try 'cp --help' for more information.\n"

  @impl true
  def names, do: ["cp"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, operands} = FlagParser.parse(args, @flag_spec)
    copy(bash, operands, options(flags))
  end

  defp options(flags) do
    mode = if flags.r or flags.a, do: :recursive, else: :shallow

    %Options{
      mode: mode,
      links: link_mode(flags, mode),
      clobber: if(flags.n, do: :never, else: :always),
      verbose?: flags.v
    }
  end

  # Bash dereferences a command-line symlink for a shallow copy only: `-r` and
  # `-a` imply `-d`. `-L` forces the link to be followed, `-P`/`-d` to be kept.
  defp link_mode(%{L: true}, _mode), do: :follow
  defp link_mode(%{P: true}, _mode), do: :preserve
  defp link_mode(%{d: true}, _mode), do: :preserve
  defp link_mode(_flags, :recursive), do: :preserve
  defp link_mode(_flags, :shallow), do: :follow

  defp copy(bash, [], _opts),
    do: {Command.error("cp: missing file operand\n" <> @try_help), bash}

  defp copy(bash, [src], _opts),
    do:
      {Command.error("cp: missing destination file operand after '#{src}'\n" <> @try_help), bash}

  # Two operands: the destination names the copy, unless it already exists as a
  # directory — then the copy lands inside it under the source's basename.
  defp copy(bash, [src, dest], opts) do
    case dest_kind(bash, dest) do
      {:ok, :directory, bash} -> copy_one(bash, src, dest_in_dir(dest, src), opts)
      {:ok, :other, bash} -> copy_one(bash, src, dest, opts)
      {:error, _error, bash} -> copy_one(bash, src, dest, opts)
    end
  end

  # Three or more operands: the last one has to be an existing directory.
  defp copy(bash, operands, opts) do
    {sources, [dest]} = Enum.split(operands, -1)

    case dest_kind(bash, dest) do
      {:ok, :directory, bash} ->
        copy_each(bash, sources, dest, opts)

      {:ok, :other, bash} ->
        {Command.error("cp: target '#{dest}': Not a directory\n"), bash}

      {:error, error, bash} ->
        {Command.error("cp: target '#{dest}': #{FS.strerror(error)}\n"), bash}
    end
  end

  # An empty operand names no file. Resolving it would produce the cwd, which is
  # not what bash does with it.
  defp dest_kind(bash, ""), do: {:error, VFS.Error.new(:enoent, path: ""), bash}

  defp dest_kind(bash, dest) do
    case FS.stat(bash.fs, FS.resolve_path(bash.cwd, dest)) do
      {:ok, %VFS.Stat{type: :directory}, fs} -> {:ok, :directory, %{bash | fs: fs}}
      {:ok, %VFS.Stat{}, fs} -> {:ok, :other, %{bash | fs: fs}}
      {:error, %VFS.Error{} = error} -> {:error, error, bash}
    end
  end

  # A failing source does not abort the run: bash copies what it can, reports
  # every failure, and exits 1.
  defp copy_each(bash, sources, dest, opts) do
    {stdout, stderr, exit_code, bash} =
      Enum.reduce(sources, {[], [], 0, bash}, fn src, {out_acc, err_acc, code_acc, bash_acc} ->
        {result, bash_acc} = copy_one(bash_acc, src, dest_in_dir(dest, src), opts)

        {[out_acc, result.stdout], [err_acc, result.stderr], max(code_acc, result.exit_code),
         bash_acc}
      end)

    {Command.result(IO.iodata_to_binary(stdout), IO.iodata_to_binary(stderr), exit_code), bash}
  end

  defp copy_one(bash, "", _dest, _opts),
    do: {Command.error("cp: cannot stat '': No such file or directory\n"), bash}

  defp copy_one(bash, src, "", opts), do: empty_dest(bash, src, opts)

  defp copy_one(bash, src, dest, opts) do
    src_path = FS.resolve_path(bash.cwd, src)
    dest_path = FS.resolve_path(bash.cwd, dest)

    if src_path == dest_path do
      {Command.error("cp: '#{src}' and '#{dest}' are the same file\n"), bash}
    else
      keep_or_copy(bash, {src, src_path}, {dest, dest_path}, opts)
    end
  end

  # `-n` leaves an existing destination alone, and says nothing about it.
  defp keep_or_copy(bash, src, {_dest, dest_path} = dest, %Options{clobber: :never} = opts) do
    case FS.exists?(bash.fs, dest_path) do
      {true, fs} -> {Command.ok(), %{bash | fs: fs}}
      {false, fs} -> copy_resolved(%{bash | fs: fs}, src, dest, opts)
    end
  end

  defp keep_or_copy(bash, src, dest, %Options{clobber: :always} = opts),
    do: copy_resolved(bash, src, dest, opts)

  defp copy_resolved(bash, {src, src_path}, {dest, dest_path}, opts) do
    case FS.lstat(bash.fs, src_path) do
      {:ok, %VFS.Stat{type: :directory}, fs} ->
        copy_dir(%{bash | fs: fs}, {src, src_path}, {dest, dest_path}, opts)

      {:ok, %VFS.Stat{type: :symlink}, fs} ->
        copy_link(%{bash | fs: fs}, {src, src_path}, {dest, dest_path}, opts)

      {:ok, %VFS.Stat{}, fs} ->
        fs
        |> FS.cp(src_path, dest_path)
        |> file_result(%{bash | fs: fs}, {src, src_path}, dest, opts)

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot stat '#{src}': #{FS.strerror(error)}\n"), bash}
    end
  end

  # A preserved link is copied as a link — dangling or not, directory or not.
  defp copy_link(bash, {src, src_path}, {dest, dest_path}, %Options{links: :preserve} = opts) do
    bash.fs
    |> FS.cp(src_path, dest_path)
    |> file_result(bash, {src, src_path}, dest, opts)
  end

  # A followed link copies whatever it names, under the link's own name: a link
  # to a directory therefore needs `-r`, exactly like a directory does.
  defp copy_link(bash, {src, src_path}, dest, %Options{links: :follow} = opts) do
    case link_target(bash.fs, src_path, 0) do
      {:ok, target_path, fs} ->
        copy_resolved(%{bash | fs: fs}, {src, target_path}, dest, opts)

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot stat '#{src}': #{FS.strerror(error)}\n"), bash}
    end
  end

  @max_link_hops 32

  # The path a symlink chain ends at, so a followed copy can hand `FS.cp/4` a
  # real file or directory instead of a link.
  defp link_target(_fs, path, hops) when hops >= @max_link_hops,
    do: {:error, VFS.Error.new(:eloop, path: path)}

  defp link_target(fs, path, hops) do
    case FS.lstat(fs, path) do
      {:ok, %VFS.Stat{type: :symlink}, fs} -> follow_link(fs, path, hops)
      {:ok, %VFS.Stat{}, fs} -> {:ok, path, fs}
      {:error, %VFS.Error{} = error} -> {:error, error}
    end
  end

  defp follow_link(fs, path, hops) do
    case FS.readlink(fs, path) do
      {:ok, target, fs} ->
        link_target(fs, FS.resolve_path(FS.dirname(path), target), hops + 1)

      {:error, %VFS.Error{} = error} ->
        {:error, error}
    end
  end

  defp copy_dir(bash, {src, _src_path}, {_dest, _dest_path}, %Options{mode: :shallow}),
    do: {Command.error("cp: -r not specified; omitting directory '#{src}'\n"), bash}

  defp copy_dir(bash, {src, src_path}, {dest, dest_path}, %Options{mode: :recursive} = opts) do
    case FS.cp(bash.fs, src_path, dest_path, recursive: true) do
      {:ok, fs} ->
        report(%{bash | fs: fs}, {src, src_path}, dest, opts)

      {:error, %VFS.Error{kind: :einval}} ->
        {Command.error("cp: cannot copy a directory, '#{src}', into itself, '#{dest}'\n"), bash}

      # Two different failures arrive as :enotdir, and bash words them
      # differently, so an lstat of the destination tells them apart: a
      # destination that exists is one we would be overwriting, while one that
      # does not resolve means an ancestor component is a regular file — which
      # bash reports as a failed stat. Both verified against GNU coreutils 9.11.
      {:error, %VFS.Error{kind: :enotdir}} ->
        case FS.lstat(bash.fs, dest_path) do
          {:ok, %VFS.Stat{}, fs} ->
            {Command.error(
               "cp: cannot overwrite non-directory '#{dest}' with directory '#{src}'\n"
             ), %{bash | fs: fs}}

          {:error, %VFS.Error{}} ->
            {Command.error("cp: cannot stat '#{dest}': #{FS.strerror(:enotdir)}\n"), bash}
        end

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot create directory '#{dest}': #{FS.strerror(error)}\n"), bash}
    end
  end

  defp file_result({:ok, fs}, bash, src, dest, opts),
    do: report(%{bash | fs: fs}, src, dest, opts)

  defp file_result({:error, %VFS.Error{kind: :eisdir}}, bash, _src, dest, _opts),
    do: {Command.error("cp: cannot overwrite directory '#{dest}' with non-directory\n"), bash}

  # Unambiguous here, unlike in copy_dir/4: a destination that exists as a
  # regular file is a plain overwrite, so :enotdir can only mean an ancestor
  # component is one — which bash words as a failed stat of the destination.
  defp file_result({:error, %VFS.Error{kind: :enotdir} = error}, bash, _src, dest, _opts),
    do: {Command.error("cp: cannot stat '#{dest}': #{FS.strerror(error)}\n"), bash}

  defp file_result({:error, %VFS.Error{} = error}, bash, _src, dest, _opts),
    do: {Command.error("cp: cannot create regular file '#{dest}': #{FS.strerror(error)}\n"), bash}

  defp report(bash, _src, _dest, %Options{verbose?: false}), do: {Command.ok(), bash}

  # `-v` names every copied entry, parents before children, in the order bash
  # walks the source.
  defp report(bash, {src, src_path}, dest, %Options{verbose?: true}) do
    {lines, fs} = report_entry(bash.fs, {src, src_path}, dest, [])
    {Command.ok(IO.iodata_to_binary(lines)), %{bash | fs: fs}}
  end

  defp report_entry(fs, {src, src_path}, dest, acc) do
    acc = [acc, "'", src, "' -> '", dest, "'\n"]

    case FS.lstat(fs, src_path) do
      {:ok, %VFS.Stat{type: :directory}, fs} -> report_children(fs, {src, src_path}, dest, acc)
      {:ok, %VFS.Stat{}, fs} -> {acc, fs}
      {:error, %VFS.Error{}} -> {acc, fs}
    end
  end

  defp report_children(fs, {src, src_path}, dest, acc) do
    case FS.readdir(fs, src_path) do
      {:ok, children, fs} ->
        Enum.reduce(children, {acc, fs}, fn child, {acc, fs} ->
          child_src = {join(src, child), FS.resolve_path(src_path, child)}
          report_entry(fs, child_src, join(dest, child), acc)
        end)

      {:error, %VFS.Error{}} ->
        {acc, fs}
    end
  end

  # Bash rejects an empty destination operand outright, naming the kind of thing
  # it could not create.
  defp empty_dest(bash, src, opts) do
    case FS.lstat(bash.fs, FS.resolve_path(bash.cwd, src)) do
      {:ok, %VFS.Stat{type: :directory}, fs} ->
        {empty_dest_error(:directory, opts), %{bash | fs: fs}}

      {:ok, %VFS.Stat{}, fs} ->
        {empty_dest_error(:file, opts), %{bash | fs: fs}}

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot stat '#{src}': #{FS.strerror(error)}\n"), bash}
    end
  end

  defp empty_dest_error(:directory, %Options{mode: :recursive}),
    do: Command.error("cp: cannot create directory '': No such file or directory\n")

  defp empty_dest_error(:directory, %Options{mode: :shallow}),
    do: Command.error("cp: -r not specified; omitting directory ''\n")

  defp empty_dest_error(:file, _opts),
    do: Command.error("cp: cannot create regular file '': No such file or directory\n")

  # The destination of a copy into a directory, spelled the way bash spells it
  # in messages: the directory operand with the source's basename appended. The
  # `dir/.` idiom copies the source's *contents*, so it keeps the destination.
  defp dest_in_dir(dest, src) do
    if dot_segment?(src), do: dest, else: join(dest, FS.basename(src))
  end

  defp dot_segment?(src), do: List.last(String.split(src, "/")) in [".", ".."]

  defp join(parent, child), do: String.trim_trailing(parent, "/") <> "/" <> child
end
