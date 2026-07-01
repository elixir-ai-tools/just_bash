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
  alias VFS.Error
  alias VFS.Path, as: VPath

  @type t :: VFS.t()

  @type mkdir_opts :: [parents: boolean()]
  @type rm_opts :: [recursive: boolean()]
  @type cp_opts :: [recursive: boolean()]
  @type write_opts :: [mode: non_neg_integer(), mtime: DateTime.t()]

  @doc """
  Create a new filesystem: a `%VFS{}` with a `JustBash.FS.Memory`
  backend (seeded with `initial_files`) mounted at `/`.
  """
  @spec new(map()) :: t()
  def new(initial_files \\ %{}) do
    VFS.new() |> VFS.mount("/", Memory.new(initial_files))
  end

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
  defdelegate mkdir(fs, path, opts \\ []), to: VFS

  @doc "See `VFS.rm/3`. Pass `recursive: true` to remove directory trees."
  @spec rm(t(), String.t(), rm_opts()) :: {:ok, t()} | {:error, Error.t()}
  defdelegate rm(fs, path, opts \\ []), to: VFS

  @doc "See `VFS.walk/3`."
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
        cp_directory(fs, src_norm, dest_norm, opts)

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
  """
  @spec mv(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def mv(fs, src, dest) do
    src_norm = normalize_path(src)
    dest_norm = normalize_path(dest)

    if src_norm == dest_norm do
      {:ok, fs}
    else
      with {:ok, fs} <- cp(fs, src_norm, dest_norm, recursive: true) do
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
