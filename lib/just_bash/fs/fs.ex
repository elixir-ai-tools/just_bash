defmodule JustBash.FS do
  @moduledoc """
  JustBash's filesystem layer: a thin facade over the
  [vfs](https://hexdocs.pm/vfs) library.

  `new/1` builds a `%VFS{}` mount table with a `JustBash.FS.Memory`
  backend mounted at `/`. Because the whole filesystem is a `%VFS{}`,
  additional backends (a read-only git repository via exgit, another
  in-memory scratch space, a caller-provided `VFS.Mountable`) can be
  mounted alongside it with `VFS.mount/3` and every bash command sees
  them transparently.

  Three groups of functions:

  - **Core operations** delegate to `VFS` and follow vfs conventions:
    reads return `{:ok, payload, fs}` (thread the updated `fs` forward —
    lazy backends cache on read), mutations return `{:ok, fs}`, and all
    errors are `%VFS.Error{}` structs.
  - **POSIX extensions** (`lstat/2`, `symlink/3`, `readlink/2`, `link/3`,
    `chmod/3`, `append_file/3`) dispatch through `JustBash.FS.POSIX`,
    degrading gracefully on backends without them.
  - **Compositions** (`cp/4`, `mv/3`) are built from the primitives, so
    they work across mounts.
  """

  alias JustBash.FS.Memory
  alias JustBash.FS.POSIX
  alias JustBash.Limit
  alias VFS.Error
  alias VFS.Path, as: VPath

  @type t :: VFS.t()

  @type mkdir_opts :: [parents: boolean()]
  @type rm_opts :: [recursive: boolean()]
  @type cp_opts :: [recursive: boolean(), deadline: Limit.Deadline.t() | nil]
  @type write_opts :: [mode: non_neg_integer(), mtime: DateTime.t()]

  @doc """
  Create a new filesystem: a `%VFS{}` with a `JustBash.FS.Memory`
  backend (seeded with `initial_files`) mounted at `/`.

  Raises `ArgumentError` when `initial_files` is not realizable as a
  filesystem: either one entry's path runs through another (see
  `validate_initial_files!/1`), or an entry collides with a directory the
  backend already holds, as `%{"/" => "x"}` does.
  """
  @spec new(map()) :: t()
  def new(initial_files \\ %{}) do
    VFS.new() |> VFS.mount("/", Memory.new(initial_files))
  end

  @doc """
  Validate a `path => content` map before seeding a filesystem with it.

  Raises `ArgumentError` when one entry's path runs *through* another
  entry — `%{"/m/j" => "x", "/m/j/a.md" => "y"}` asks for a file inside a
  regular file, which no filesystem can hold. See
  `JustBash.FS.Memory.validate_initial_files!/1`.
  """
  @spec validate_initial_files!(map()) :: :ok
  defdelegate validate_initial_files!(initial_files), to: Memory

  # ── path helpers (pure) ──────────────────────────────────────────────────
  #
  # Tolerant wrappers over `VFS.Path`: bash deals in user input, so these
  # accept relative and empty paths by rooting them at "/", where
  # `VFS.Path.normalize/1` would raise.

  @doc """
  Normalize a filesystem path. Relative input is rooted at `/`.
  """
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(""), do: "/"
  def normalize_path("/" <> _ = path), do: VPath.normalize(path)
  def normalize_path(path), do: VPath.normalize("/" <> path)

  @doc """
  Get the directory name (parent path) of a path.
  """
  @spec dirname(String.t()) :: String.t()
  def dirname(path), do: path |> normalize_path() |> VPath.dirname()

  @doc """
  Get the base name (last segment) of a path. The basename of `/` is `/`.
  """
  @spec basename(String.t()) :: String.t()
  def basename(path) do
    case normalize_path(path) do
      "/" -> "/"
      normalized -> VPath.basename(normalized)
    end
  end

  @doc """
  Resolve `path` relative to `base`. Absolute paths ignore the base.
  """
  @spec resolve_path(String.t(), String.t()) :: String.t()
  def resolve_path(_base, "/" <> _ = path), do: normalize_path(path)
  def resolve_path(base, path), do: VPath.join(normalize_path(base), path)

  @doc """
  Does the way `path` is spelled require it to name a directory?

  POSIX resolves a trailing slash as a trailing `/.`, so `f/` is not another
  spelling of the regular file `f` — it is an assertion that `f` is a
  directory. The `.` and `..` components the slash stands for say the same
  thing. `resolve_path/2` normalizes all of them away, so a caller that writes
  through a user-supplied path asks this of the operand before trusting where
  it resolved to.

  An empty operand names nothing at all, which is a different complaint.
  """
  @directory_components ["", ".", ".."]

  @spec directory_spelling?(String.t()) :: boolean()
  def directory_spelling?(""), do: false

  def directory_spelling?(path) do
    last = path |> String.split("/") |> List.last()
    last in @directory_components
  end

  @doc """
  Hold `spelling` — a path as an operand wrote it, read relative to `base` —
  to what its spelling promised: `{:ok, fs}` unless it demands a directory
  (see `directory_spelling?/1`) and what it demands it of is not one.

  What it demands it of is the last component the spelling names outright, not
  where `resolve_path/2` says the whole thing lands: `..` is collapsed
  lexically, so `/f/..` resolves to `/` — a directory whatever `/f` is — while
  the kernel cannot walk up out of the regular file `/f` at all.

  The error is the one `stat("f/")` itself gives: `:enotdir` when something
  that is not a directory is already there, naming the operand as the caller
  spelled it, and whatever `stat/2` reported otherwise. `:enoent` means the
  destination does not exist yet, which a caller about to create the directory
  — a recursive copy, say — can ignore.
  """
  @spec check_directory_spelling(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def check_directory_spelling(fs, base, spelling) do
    if directory_spelling?(spelling) do
      require_directory(fs, spelling, asserted_directory(base, spelling))
    else
      {:ok, fs}
    end
  end

  # The path `spelling` asserts is a directory: everything before the run of
  # `/`, `.` and `..` components trailing it. Holding that one path is enough
  # — every component the run walks through afterwards is an ancestor of it,
  # and an ancestor of a directory is a directory. A spelling that names
  # nothing else (`/`, `.`, `..`) asserts only about where it resolved.
  defp asserted_directory(base, spelling) do
    named =
      spelling
      |> String.split("/")
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 in @directory_components))
      |> Enum.reverse()

    case named do
      [] -> resolve_path(base, spelling)
      components -> resolve_path(base, Enum.join(components, "/"))
    end
  end

  # ── core operations (delegated to VFS) ───────────────────────────────────

  @doc "See `VFS.read_file/2`."
  @spec read_file(t(), String.t()) :: {:ok, binary(), t()} | {:error, Error.t()}
  defdelegate read_file(fs, path), to: VFS

  @doc "See `VFS.stream_read/3`."
  @spec stream_read(t(), String.t(), keyword()) ::
          {:ok, Enumerable.t(), t()} | {:error, Error.t()}
  defdelegate stream_read(fs, path, opts \\ []), to: VFS

  @doc "See `VFS.write_file/4`. The default backend honors `:mode` and `:mtime` opts."
  @spec write_file(t(), String.t(), binary(), write_opts()) ::
          {:ok, t()} | {:error, Error.t()}
  defdelegate write_file(fs, path, content, opts \\ []), to: VFS

  @doc "See `VFS.exists?/2`."
  @spec exists?(t(), String.t()) :: {boolean(), t()}
  defdelegate exists?(fs, path), to: VFS

  @doc "See `VFS.stat/2`. Follows symlinks."
  @spec stat(t(), String.t()) :: {:ok, VFS.Stat.t(), t()} | {:error, Error.t()}
  defdelegate stat(fs, path), to: VFS

  @doc "See `VFS.readdir/2`."
  @spec readdir(t(), String.t()) :: {:ok, Enumerable.t(), t()} | {:error, Error.t()}
  defdelegate readdir(fs, path), to: VFS

  @doc "See `VFS.mkdir/3`. Pass `parents: true` for `mkdir -p` behavior."
  @spec mkdir(t(), String.t(), mkdir_opts()) :: {:ok, t()} | {:error, Error.t()}
  def mkdir(fs, path, opts \\ []) do
    # The 0.3 option was `recursive:`; silently ignoring it would make
    # `mkdir -p`-style callers fail far from the cause. Refuse loudly.
    if Keyword.has_key?(opts, :recursive) do
      raise ArgumentError,
            "JustBash.FS.mkdir/3 has no :recursive option — vfs names it parents: true. " <>
              "See UPGRADING.md."
    end

    VFS.mkdir(fs, path, opts)
  end

  @doc "See `VFS.rm/3`. Pass `recursive: true` to remove directory trees."
  @spec rm(t(), String.t(), rm_opts()) :: {:ok, t()} | {:error, Error.t()}
  def rm(fs, path, opts \\ []) do
    # The 0.3 option was `force:`; silently ignoring it would surface as
    # spurious :enoent errors. Refuse loudly.
    if Keyword.has_key?(opts, :force) do
      raise ArgumentError,
            "JustBash.FS.rm/3 has no :force option — match " <>
              "{:error, %VFS.Error{kind: :enoent}} at the call site instead. See UPGRADING.md."
    end

    VFS.rm(fs, path, opts)
  end

  @doc """
  See `VFS.walk/3`.

  This is an unbounded enumeration and no command in `lib/` uses it; a caller
  that walks an untrusted tree should pipe it through
  `JustBash.Limit.enforce_deadline/2`, the way `JustBash.Commands.Seq` does.
  """
  @spec walk(t(), String.t(), keyword()) :: Enumerable.t()
  defdelegate walk(fs, root, opts \\ []), to: VFS

  # ── POSIX extensions (dispatched through JustBash.FS.POSIX) ─────────────

  @doc "Get stat information without following symlinks."
  @spec lstat(t(), String.t()) :: {:ok, VFS.Stat.t(), t()} | {:error, Error.t()}
  defdelegate lstat(fs, path), to: POSIX

  @doc "Read the target of a symbolic link."
  @spec readlink(t(), String.t()) :: {:ok, String.t(), t()} | {:error, Error.t()}
  defdelegate readlink(fs, path), to: POSIX

  @doc "Create a symbolic link at `link_path` pointing to `target`."
  @spec symlink(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  defdelegate symlink(fs, target, link_path), to: POSIX

  @doc "Create a hard link."
  @spec link(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  defdelegate link(fs, existing_path, new_path), to: POSIX

  @doc "Change file/directory permissions."
  @spec chmod(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  defdelegate chmod(fs, path, mode), to: POSIX

  @doc "Append content to a file, creating it if it doesn't exist."
  @spec append_file(t(), String.t(), binary()) :: {:ok, t()} | {:error, Error.t()}
  defdelegate append_file(fs, path, content), to: POSIX

  # ── compositions ─────────────────────────────────────────────────────────

  @doc """
  Copy a file, symlink, or (with `recursive: true`) directory tree.

  Composed from the vfs primitives plus the POSIX extensions, so it
  works across mounts: regular files copy content, mode, and mtime;
  symlinks copy the link itself when the destination backend supports
  symlinks.

  A recursive copy whose destination lies inside the source fails with
  `:einval` instead of recursing forever — every pass would add new
  children under the source it is still walking. Both operands are
  resolved through any symlinked components before that test, so a
  destination that only *reaches* the source through a link is caught
  too.

  `:deadline` — a `JustBash.Limit.Deadline` (or `nil`). A recursive copy is a
  single step as far as the step counter is concerned, so a large tree is
  otherwise unbounded; with a deadline, each directory descended into checks
  the wall clock and raises `JustBash.Limit.ExceededError` once it has passed.
  """
  @spec cp(t(), String.t(), String.t(), cp_opts()) :: {:ok, t()} | {:error, Error.t()}
  def cp(fs, src, dest, opts \\ []) do
    src_norm = normalize_path(src)
    dest_norm = normalize_path(dest)
    recursive = Keyword.get(opts, :recursive, false)

    case lstat(fs, src_norm) do
      {:ok, %VFS.Stat{type: :directory}, _fs} when not recursive ->
        {:error, Error.new(:eisdir, path: src_norm)}

      {:ok, %VFS.Stat{type: :directory}, fs} ->
        {src_real, fs} = resolve_links(fs, src_norm)
        {dest_real, fs} = resolve_links(fs, dest_norm)

        if within?(dest_real, src_real) do
          {:error, Error.new(:einval, path: dest_norm)}
        else
          cp_directory(fs, src_norm, dest_norm, opts)
        end

      {:ok, %VFS.Stat{type: :symlink}, fs} ->
        cp_symlink(fs, src_norm, dest_norm)

      {:ok, %VFS.Stat{} = stat, fs} ->
        cp_regular(fs, src_norm, dest_norm, stat)

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end

  @doc """
  Move/rename a file, symlink, or directory tree. Composed as a
  recursive copy followed by a recursive remove, so it works across
  mounts.

  A destination symlink is replaced, not followed (POSIX `rename/2`
  semantics) — the opposite of `cp/4`, which writes through it.

  Moving a directory into its own subtree fails with `:einval` (see
  `cp/4`) rather than looping.
  """
  @spec mv(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def mv(fs, src, dest) do
    src_norm = normalize_path(src)
    dest_norm = normalize_path(dest)

    if src_norm == dest_norm do
      {:ok, fs}
    else
      with {:ok, fs} <- unlink_dest_symlink(fs, dest_norm),
           {:ok, fs} <- cp(fs, src_norm, dest_norm, recursive: true) do
        rm(fs, src_norm, recursive: true)
      end
    end
  end

  # ── error formatting ─────────────────────────────────────────────────────

  @doc """
  The conventional strerror-style message for a `%VFS.Error{}` or error
  kind, as bash utilities print them.
  """
  @spec strerror(Error.t() | atom()) :: String.t()
  def strerror(%Error{kind: kind}), do: strerror(kind)
  def strerror(:enoent), do: "No such file or directory"
  def strerror(:eexist), do: "File exists"
  def strerror(:eisdir), do: "Is a directory"
  def strerror(:enotdir), do: "Not a directory"
  def strerror(:enotempty), do: "Directory not empty"
  def strerror(:eacces), do: "Permission denied"
  def strerror(:erofs), do: "Read-only file system"
  def strerror(:enotsup), do: "Operation not supported"
  def strerror(:einval), do: "Invalid argument"
  def strerror(:eloop), do: "Too many levels of symbolic links"
  def strerror(:exdev), do: "Invalid cross-device link"
  def strerror(:eio), do: "Input/output error"
  def strerror(kind) when is_atom(kind), do: to_string(kind)

  # ── private ──────────────────────────────────────────────────────────────

  # The stat behind `check_directory_spelling/3`. The error names the operand
  # as it was spelled, since that spelling is what the caller reports.
  defp require_directory(fs, spelling, resolved) do
    case stat(fs, resolved) do
      {:ok, %VFS.Stat{type: :directory}, fs} -> {:ok, fs}
      {:ok, %VFS.Stat{}, _fs} -> {:error, Error.new(:enotdir, path: spelling)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # Is `dest` the same path as `src`, or nested inside it? Everything is
  # inside the root, so a recursive copy of "/" never has a safe destination.
  #
  # Callers pass paths already resolved by `resolve_links/2`: this is a prefix
  # test on spellings, and a symlink makes a spelling lie.
  defp within?(_dest, "/"), do: true
  defp within?(dest, src), do: dest == src or String.starts_with?(dest, src <> "/")

  # How many links a single path may traverse before we stop resolving it.
  @symlink_hops 32

  # Resolve a path one component at a time, following symlinks as they are
  # met, so `within?/2` compares where paths land rather than how they are
  # spelled. With `/l -> /a`, "/l/x" names a place inside "/a" while sharing
  # no prefix with it; without this the recursive copy created children under
  # the tree it was still walking and never terminated, and `mv` — which
  # composes copy-then-remove — deleted the source after copying nothing.
  #
  # Best effort on purpose. A path that cannot be resolved (a link cycle, a
  # component that is a regular file) falls back to its lexical form: the
  # guard stays conservative and the copy that follows reports the real error
  # in its own words, rather than this helper inventing one.
  defp resolve_links(fs, path) do
    resolve_components(fs, split_path(path), "/", 0, path)
  end

  defp resolve_components(fs, [], resolved, _hops, _lexical), do: {resolved, fs}

  defp resolve_components(fs, _rest, _resolved, hops, lexical) when hops >= @symlink_hops,
    do: {lexical, fs}

  defp resolve_components(fs, [component | rest], parent, hops, lexical) do
    candidate = join_component(parent, component)

    case lstat(fs, candidate) do
      # A link replaces everything resolved so far: its target is re-resolved
      # from the root, with the components after it still to walk. A relative
      # target resolves against the directory holding the link.
      {:ok, %VFS.Stat{type: :symlink}, fs} ->
        case readlink(fs, candidate) do
          {:ok, target, fs} ->
            target_components = parent |> resolve_path(target) |> split_path()
            resolve_components(fs, target_components ++ rest, "/", hops + 1, lexical)

          {:error, %Error{}} ->
            {lexical, fs}
        end

      {:ok, %VFS.Stat{}, fs} ->
        resolve_components(fs, rest, candidate, hops, lexical)

      # Nothing here yet — a copy destination usually does not exist. Nothing
      # missing can be a symlink, so the rest of the path joins on literally.
      {:error, %Error{kind: :enoent}} ->
        {Enum.reduce(rest, candidate, &join_component(&2, &1)), fs}

      {:error, %Error{}} ->
        {lexical, fs}
    end
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp join_component("/", component), do: "/" <> component
  defp join_component(parent, component), do: parent <> "/" <> component

  # rename(2) replaces a destination symlink rather than writing through
  # it (unlike cp, whose write_file follows the link). Remove the link
  # first so the copy lands at the destination name itself.
  defp unlink_dest_symlink(fs, dest_norm) do
    case lstat(fs, dest_norm) do
      {:ok, %VFS.Stat{type: :symlink}, fs} -> rm(fs, dest_norm)
      {:ok, %VFS.Stat{}, fs} -> {:ok, fs}
      {:error, %Error{kind: :enoent}} -> {:ok, fs}
      {:error, %Error{} = err} -> {:error, err}
    end
  end

  defp cp_regular(fs, src_norm, dest_norm, %VFS.Stat{} = stat) do
    with {:ok, content, fs} <- read_file(fs, src_norm) do
      opts = if stat.mode, do: [mode: stat.mode, mtime: stat.mtime], else: [mtime: stat.mtime]
      write_file(fs, dest_norm, content, opts)
    end
  end

  defp cp_symlink(fs, src_norm, dest_norm) do
    with {:ok, target, fs} <- readlink(fs, src_norm) do
      symlink(fs, target, dest_norm)
    end
  end

  defp cp_directory(fs, src_norm, dest_norm, opts) do
    case mkdir(fs, dest_norm, parents: true) do
      {:ok, fs} ->
        cp_children(fs, src_norm, dest_norm, opts)

      {:error, %Error{kind: :eexist}} ->
        {:error, Error.new(:enotdir, path: dest_norm)}

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end

  defp cp_children(fs, src_norm, dest_norm, opts) do
    Limit.check_deadline!(Keyword.get(opts, :deadline))

    with {:ok, children, fs} <- readdir(fs, src_norm) do
      Enum.reduce_while(children, {:ok, fs}, fn child, {:ok, acc_fs} ->
        src_child = join_child(src_norm, child)
        dest_child = join_child(dest_norm, child)

        case cp(acc_fs, src_child, dest_child, opts) do
          {:ok, _} = ok -> {:cont, ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp join_child("/", child), do: "/" <> child
  defp join_child(parent, child), do: parent <> "/" <> child
end
