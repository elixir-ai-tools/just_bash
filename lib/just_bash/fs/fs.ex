defmodule JustBash.Fs do
  @moduledoc """
  Virtual filesystem with a mount-table-based routing layer.

  `%JustBash.Fs{}` owns a list of mounts — `{mountpoint, module, backend_state}`
  triples — and dispatches every filesystem operation to the appropriate backend
  via longest-prefix mountpoint matching.

  Pure path helpers (`normalize_path/1`, `resolve_path/2`, `dirname/1`,
  `basename/1`) live here as plain module functions shared by all backends.
  """

  alias JustBash.Fs.InMemoryFs

  @type mount :: {mountpoint :: String.t(), module(), backend_state :: term()}

  @type t :: %__MODULE__{mounts: [mount()]}

  defstruct mounts: []

  @type stat_result :: %{
          is_file: boolean(),
          is_directory: boolean(),
          is_symbolic_link: boolean(),
          mode: non_neg_integer(),
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type mkdir_opts :: [recursive: boolean()]
  @type rm_opts :: [recursive: boolean(), force: boolean()]
  @type cp_opts :: [recursive: boolean()]
  @type write_opts :: [mode: non_neg_integer(), mtime: DateTime.t()]

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Create a new filesystem with a root `/` mount.

  ## Variants

      Fs.new()                          # root backed by InMemoryFs
      Fs.new(%{"/a.txt" => "hi"})       # InMemoryFs seeded with initial files
      Fs.new(root: {MyBackend, state})  # custom root backend

  ## Examples

      iex> fs = JustBash.Fs.new()
      iex> fs = JustBash.Fs.new(%{"/hello.txt" => "world"})
      iex> fs = JustBash.Fs.new(root: {JustBash.Fs.InMemoryFs, JustBash.Fs.InMemoryFs.new()})
  """
  @spec new(map() | keyword()) :: t()
  def new(opts \\ %{})

  def new(root: {module, state}) do
    %__MODULE__{mounts: [{"/", module, state}]}
  end

  def new(initial_files) when is_map(initial_files) do
    root_state = InMemoryFs.new(initial_files)
    %__MODULE__{mounts: [{"/", InMemoryFs, root_state}]}
  end

  # ---------------------------------------------------------------------------
  # Mount management
  # ---------------------------------------------------------------------------

  @doc """
  Mount a backend at the given mountpoint.

  The mountpoint must be absolute and is normalized before storage.
  Duplicate mountpoints return `{:error, :eexist}`.
  Non-absolute mountpoints return `{:error, :einval}`.
  """
  @spec mount(t(), String.t(), module(), term()) :: {:ok, t()} | {:error, :einval | :eexist}
  def mount(%__MODULE__{mounts: mounts} = fs, mountpoint, module, backend_state) do
    if String.starts_with?(mountpoint, "/") do
      normalized =
        mountpoint
        |> normalize_path()
        |> String.trim_trailing("/")
        |> case do
          "" -> "/"
          other -> other
        end

      if Enum.any?(mounts, fn {mp, _mod, _state} -> mp == normalized end) do
        {:error, :eexist}
      else
        {:ok, %{fs | mounts: mounts ++ [{normalized, module, backend_state}]}}
      end
    else
      {:error, :einval}
    end
  end

  @doc """
  Unmount the backend at the given mountpoint.

  The root `/` mount cannot be unmounted (returns `{:error, :ebusy}`).
  Non-existent mountpoints return `{:error, :enoent}`.
  """
  @spec umount(t(), String.t()) :: {:ok, t()} | {:error, :ebusy | :enoent}
  def umount(%__MODULE__{}, "/"), do: {:error, :ebusy}

  def umount(%__MODULE__{mounts: mounts} = fs, mountpoint) do
    normalized = normalize_path(mountpoint)

    case Enum.split_with(mounts, fn {mp, _mod, _state} -> mp == normalized end) do
      {[], _rest} -> {:error, :enoent}
      {_found, rest} -> {:ok, %{fs | mounts: rest}}
    end
  end

  @doc """
  List all current mounts as `{mountpoint, module}` pairs.
  """
  @spec mounts(t()) :: [{String.t(), module()}]
  def mounts(%__MODULE__{mounts: mounts}) do
    Enum.map(mounts, fn {mp, mod, _state} -> {mp, mod} end)
  end

  # ---------------------------------------------------------------------------
  # Pure path helpers (canonical implementations)
  # ---------------------------------------------------------------------------

  @doc """
  Normalize a filesystem path.

  Handles:
  - Empty paths and "/" -> "/"
  - Trailing slashes removal
  - Resolving "." and ".." components
  - Ensuring leading "/"

  ## Examples

      iex> JustBash.Fs.normalize_path("/home/user/../user/./file")
      "/home/user/file"
  """
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(path) do
    if path == "" or path == "/" do
      "/"
    else
      normalized =
        path
        |> String.trim_trailing("/")
        |> ensure_leading_slash()

      parts =
        normalized
        |> String.split("/")
        |> Enum.filter(&(&1 != "" and &1 != "."))

      resolved =
        Enum.reduce(parts, [], fn
          "..", [] -> []
          "..", acc -> tl(acc)
          part, acc -> [part | acc]
        end)
        |> Enum.reverse()

      "/" <> Enum.join(resolved, "/")
    end
  end

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path

  @doc """
  Get the directory name (parent path) of a path.

  ## Examples

      iex> JustBash.Fs.dirname("/home/user/file.txt")
      "/home/user"
      iex> JustBash.Fs.dirname("/file.txt")
      "/"
  """
  @spec dirname(String.t()) :: String.t()
  def dirname(path) do
    normalized = normalize_path(path)

    if normalized == "/" do
      "/"
    else
      case normalized |> String.split("/") |> Enum.filter(&(&1 != "")) |> Enum.reverse() do
        [_] -> "/"
        [_ | rest] -> "/" <> (rest |> Enum.reverse() |> Enum.join("/"))
        [] -> "/"
      end
    end
  end

  @doc """
  Get the base name (file name) of a path.

  ## Examples

      iex> JustBash.Fs.basename("/home/user/file.txt")
      "file.txt"
  """
  @spec basename(String.t()) :: String.t()
  def basename(path) do
    normalized = normalize_path(path)

    if normalized == "/" do
      "/"
    else
      normalized |> String.split("/") |> List.last()
    end
  end

  @doc """
  Resolve a path relative to a base path.

  ## Examples

      iex> JustBash.Fs.resolve_path("/home/user", "file.txt")
      "/home/user/file.txt"
      iex> JustBash.Fs.resolve_path("/home/user", "/etc/passwd")
      "/etc/passwd"
  """
  @spec resolve_path(String.t(), String.t()) :: String.t()
  def resolve_path(_base, "/" <> _ = path), do: normalize_path(path)

  def resolve_path(base, path) do
    combined = if base == "/", do: "/" <> path, else: base <> "/" <> path
    normalize_path(combined)
  end

  # ---------------------------------------------------------------------------
  # Query ops — dispatch to resolving backend
  # ---------------------------------------------------------------------------

  @doc """
  Check if a path exists in the filesystem.

  Returns `true` if the path is a registered mountpoint, if it has any
  descendant mounts (making it a synthetic ancestor directory), or if
  the resolving backend reports it exists.
  """
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = fs, path) do
    normalized = normalize_path(path)

    cond do
      mountpoint?(fs, normalized) ->
        true

      has_descendant_mount?(fs, normalized) ->
        true

      true ->
        {mod, state, backend_path, _idx} = resolve(fs, normalized)
        mod.exists?(state, backend_path)
    end
  end

  @doc """
  Get stat information for a path (follows symlinks).

  If the path is a registered mountpoint or has child mounts but does not
  exist in the resolving backend, a synthetic directory stat is returned.
  """
  @spec stat(t(), String.t()) :: {:ok, stat_result()} | {:error, atom()}
  def stat(%__MODULE__{} = fs, path) do
    normalized = normalize_path(path)

    if mountpoint?(fs, normalized) do
      {:ok, synthetic_dir_stat()}
    else
      {mod, state, backend_path, _idx} = resolve(fs, normalized)

      case mod.stat(state, backend_path) do
        {:error, :enoent} when normalized != "/" ->
          if has_descendant_mount?(fs, normalized) do
            {:ok, synthetic_dir_stat()}
          else
            {:error, :enoent}
          end

        other ->
          other
      end
    end
  end

  @doc """
  Get stat information for a path (does NOT follow symlinks).

  Same synthetic-visibility rules as `stat/2`.
  """
  @spec lstat(t(), String.t()) :: {:ok, stat_result()} | {:error, atom()}
  def lstat(%__MODULE__{} = fs, path) do
    normalized = normalize_path(path)

    if mountpoint?(fs, normalized) do
      {:ok, synthetic_dir_stat()}
    else
      {mod, state, backend_path, _idx} = resolve(fs, normalized)

      case mod.lstat(state, backend_path) do
        {:error, :enoent} when normalized != "/" ->
          if has_descendant_mount?(fs, normalized) do
            {:ok, synthetic_dir_stat()}
          else
            {:error, :enoent}
          end

        other ->
          other
      end
    end
  end

  @doc """
  Read the contents of a file.
  """
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def read_file(%__MODULE__{} = fs, path) do
    {mod, state, backend_path, _idx} = resolve(fs, path)
    mod.read_file(state, backend_path)
  end

  @doc """
  Read directory contents.

  The returned list is the union of the backend's entries and the basenames
  of any child mounts of the given path, deduplicated and sorted. If the
  backend returns `:enoent` but child mounts exist, a purely synthetic
  listing is returned.
  """
  @spec readdir(t(), String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def readdir(%__MODULE__{} = fs, path) do
    normalized = normalize_path(path)
    {mod, state, backend_path, _idx} = resolve(fs, normalized)
    synthetic = child_mount_basenames(fs, normalized)

    case mod.readdir(state, backend_path) do
      {:ok, entries} ->
        merged = Enum.uniq(entries ++ synthetic) |> Enum.sort()
        {:ok, merged}

      {:error, :enoent} ->
        if synthetic != [] or mountpoint?(fs, normalized) or
             has_descendant_mount?(fs, normalized) do
          {:ok, Enum.sort(synthetic)}
        else
          {:error, :enoent}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Read the target of a symbolic link.
  """
  @spec readlink(t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def readlink(%__MODULE__{} = fs, path) do
    {mod, state, backend_path, _idx} = resolve(fs, path)
    mod.readlink(state, backend_path)
  end

  @doc """
  Get all paths in the filesystem.
  """
  @spec get_all_paths(t()) :: [String.t()]
  def get_all_paths(%__MODULE__{mounts: mounts}) do
    Enum.flat_map(mounts, fn {mountpoint, mod, state} ->
      do_get_all_paths(mod, state, "/")
      |> Enum.map(fn
        "/" -> mountpoint
        backend_path -> join_mount_path(mountpoint, backend_path)
      end)
    end)
    |> Enum.uniq()
  end

  defp do_get_all_paths(mod, state, dir) do
    case mod.readdir(state, dir) do
      {:ok, children} ->
        children_paths =
          Enum.flat_map(children, fn child ->
            child_path = if dir == "/", do: "/" <> child, else: dir <> "/" <> child
            [child_path | do_get_all_paths(mod, state, child_path)]
          end)

        [dir | children_paths]

      {:error, _} ->
        [dir]
    end
  end

  defp join_mount_path("/", backend_path), do: backend_path
  defp join_mount_path(mountpoint, "/"), do: mountpoint
  defp join_mount_path(mountpoint, "/" <> rest), do: mountpoint <> "/" <> rest

  # ---------------------------------------------------------------------------
  # Mutating ops — dispatch + thread state back into mount list
  # ---------------------------------------------------------------------------

  @doc """
  Write content to a file.
  """
  @spec write_file(t(), String.t(), binary()) :: {:ok, t()} | {:error, atom()}
  def write_file(fs, path, content), do: write_file(fs, path, content, [])

  @spec write_file(t(), String.t(), binary(), write_opts()) :: {:ok, t()} | {:error, atom()}
  def write_file(%__MODULE__{} = fs, path, content, opts) do
    {mod, state, backend_path, idx} = resolve(fs, path)

    case mod.write_file(state, backend_path, content, opts) do
      {:ok, new_state} -> {:ok, put_mount_state(fs, idx, new_state)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Append content to a file.
  """
  @spec append_file(t(), String.t(), binary()) :: {:ok, t()} | {:error, atom()}
  def append_file(%__MODULE__{} = fs, path, content) do
    {mod, state, backend_path, idx} = resolve(fs, path)

    case mod.append_file(state, backend_path, content) do
      {:ok, new_state} -> {:ok, put_mount_state(fs, idx, new_state)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Create a directory.
  """
  @spec mkdir(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def mkdir(fs, path), do: mkdir(fs, path, [])

  @spec mkdir(t(), String.t(), mkdir_opts()) :: {:ok, t()} | {:error, atom()}
  def mkdir(%__MODULE__{} = fs, path, opts) do
    {mod, state, backend_path, idx} = resolve(fs, path)

    case mod.mkdir(state, backend_path, opts) do
      {:ok, new_state} -> {:ok, put_mount_state(fs, idx, new_state)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Remove a file or directory.

  When `rm("/", recursive: true, force: true)` is called, every mount's
  backend is cleared individually. The mount table itself is not modified —
  mounts remain registered, only their contents are emptied.
  """
  @spec rm(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def rm(fs, path), do: rm(fs, path, [])

  @spec rm(t(), String.t(), rm_opts()) :: {:ok, t()} | {:error, atom()}
  def rm(%__MODULE__{mounts: mounts} = fs, path, opts) do
    normalized = normalize_path(path)
    recursive = Keyword.get(opts, :recursive, false)
    force = Keyword.get(opts, :force, false)

    if normalized == "/" and recursive and force do
      # Iterate all mounts, clear each backend at its root
      new_mounts =
        Enum.map(mounts, fn {mp, mod, state} ->
          case mod.rm(state, "/", opts) do
            {:ok, new_state} -> {mp, mod, new_state}
            {:error, _} -> {mp, mod, state}
          end
        end)

      {:ok, %{fs | mounts: new_mounts}}
    else
      {mod, state, backend_path, idx} = resolve(fs, normalized)

      case mod.rm(state, backend_path, opts) do
        {:ok, new_state} -> {:ok, put_mount_state(fs, idx, new_state)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Change file/directory permissions.
  """
  @spec chmod(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def chmod(%__MODULE__{} = fs, path, mode) do
    {mod, state, backend_path, idx} = resolve(fs, path)

    case mod.chmod(state, backend_path, mode) do
      {:ok, new_state} -> {:ok, put_mount_state(fs, idx, new_state)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Create a symbolic link.

  Absolute symlink targets that would cross a mount boundary are refused
  with `{:error, :einval}`. Relative targets are allowed (they resolve
  within the backend's own coordinate space).
  """
  @spec symlink(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def symlink(%__MODULE__{} = fs, target, link_path) do
    {mod, state, backend_path, idx} = resolve(fs, link_path)

    if symlink_crosses_mount?(fs, target, link_path, idx) do
      {:error, :einval}
    else
      case mod.symlink(state, target, backend_path) do
        {:ok, new_state} -> {:ok, put_mount_state(fs, idx, new_state)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Create a hard link.
  """
  @spec link(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def link(%__MODULE__{} = fs, existing_path, new_path) do
    {_mod1, _state1, backend_existing, idx1} = resolve(fs, existing_path)
    {mod2, state2, backend_new, idx2} = resolve(fs, new_path)

    if idx1 != idx2 do
      {:error, :exdev}
    else
      case mod2.link(state2, backend_existing, backend_new) do
        {:ok, new_state} -> {:ok, put_mount_state(fs, idx2, new_state)}
        {:error, _} = err -> err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Composed ops (not backend callbacks)
  # ---------------------------------------------------------------------------

  @doc """
  Copy a file or directory.

  Composed at the Fs level via read_file + write_file so it works transparently
  across mount boundaries.
  """
  @spec cp(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def cp(fs, src, dest), do: cp(fs, src, dest, [])

  @spec cp(t(), String.t(), String.t(), cp_opts()) :: {:ok, t()} | {:error, atom()}
  def cp(%__MODULE__{} = fs, src, dest, opts) do
    recursive = Keyword.get(opts, :recursive, false)

    case stat(fs, src) do
      {:error, _} = err ->
        err

      {:ok, %{is_directory: true}} when not recursive ->
        {:error, :eisdir}

      {:ok, %{is_directory: true}} ->
        cp_directory(fs, src, dest, opts)

      {:ok, _stat} ->
        cp_single(fs, src, dest)
    end
  end

  defp cp_single(fs, src, dest) do
    {src_mod, src_state, src_backend, _src_idx} = resolve(fs, src)

    case src_mod.lstat(src_state, src_backend) do
      {:ok, %{is_symbolic_link: true}} ->
        case src_mod.readlink(src_state, src_backend) do
          {:ok, target} -> symlink(fs, target, dest)
          {:error, _} = err -> err
        end

      {:ok, _} ->
        case read_file(fs, src) do
          {:ok, content} ->
            case stat(fs, src) do
              {:ok, %{mode: mode}} -> write_file(fs, dest, content, mode: mode)
              _ -> write_file(fs, dest, content)
            end

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp cp_directory(fs, src, dest, opts) do
    with {:ok, fs} <- cp_mkdir_dest(fs, dest),
         {:ok, children} <- readdir(fs, src) do
      cp_children(fs, src, dest, children, opts)
    end
  end

  defp cp_mkdir_dest(fs, dest) do
    case mkdir(fs, dest, recursive: true) do
      {:ok, _} = ok -> ok
      {:error, :eexist} -> {:error, :enotdir}
      {:error, _} = err -> err
    end
  end

  defp cp_children(fs, src, dest, children, opts) do
    Enum.reduce_while(children, {:ok, fs}, fn child, {:ok, acc_fs} ->
      src_child = if src == "/", do: "/" <> child, else: src <> "/" <> child
      dest_child = if dest == "/", do: "/" <> child, else: dest <> "/" <> child

      case cp(acc_fs, src_child, dest_child, opts) do
        {:ok, _} = ok -> {:cont, ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Move/rename a file or directory.

  Same-mount moves are performed within the backend. Cross-mount moves
  return `{:error, :exdev}`.
  """
  @spec mv(t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def mv(%__MODULE__{} = fs, src, dest) do
    src_norm = normalize_path(src)
    dest_norm = normalize_path(dest)

    if src_norm == dest_norm do
      {:ok, fs}
    else
      {_mod1, _state1, _bp1, idx1} = resolve(fs, src_norm)
      {_mod2, _state2, _bp2, idx2} = resolve(fs, dest_norm)

      if idx1 != idx2 do
        {:error, :exdev}
      else
        case cp(fs, src_norm, dest_norm, recursive: true) do
          {:ok, fs} -> rm(fs, src_norm, recursive: true)
          error -> error
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mount-table resolution (private)
  # ---------------------------------------------------------------------------

  @spec resolve(t(), String.t()) :: {module(), term(), String.t(), non_neg_integer()}
  defp resolve(%__MODULE__{mounts: mounts}, path) do
    normalized = normalize_path(path)

    {mount, idx} =
      mounts
      |> Enum.with_index()
      |> Enum.filter(fn {{mp, _mod, _state}, _idx} ->
        normalized == mp or String.starts_with?(normalized, mp <> "/") or mp == "/"
      end)
      |> Enum.max_by(fn {{mp, _mod, _state}, _idx} -> byte_size(mp) end)

    {mountpoint, mod, state} = mount

    backend_path =
      if normalized == mountpoint do
        "/"
      else
        "/" <> String.trim_leading(normalized, mountpoint <> "/")
      end

    {mod, state, backend_path, idx}
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp put_mount_state(%__MODULE__{mounts: mounts} = fs, idx, new_state) do
    {mountpoint, mod, _old_state} = Enum.at(mounts, idx)
    new_mounts = List.replace_at(mounts, idx, {mountpoint, mod, new_state})
    %{fs | mounts: new_mounts}
  end

  # ---------------------------------------------------------------------------
  # Synthetic mountpoint helpers
  # ---------------------------------------------------------------------------

  # True if `path` is exactly a registered mountpoint.
  defp mountpoint?(%__MODULE__{mounts: mounts}, path) do
    Enum.any?(mounts, fn {mp, _mod, _state} -> mp == path end)
  end

  # True if any mount's mountpoint starts with `path <> "/"`.
  defp has_descendant_mount?(%__MODULE__{mounts: mounts}, path) do
    prefix = path <> "/"

    Enum.any?(mounts, fn {mp, _mod, _state} ->
      mp != "/" and String.starts_with?(mp, prefix)
    end)
  end

  # Returns the immediate child names visible under `path` due to mounts.
  # For a mount at `/data/nested/sub`, listing `/data` yields `"nested"`.
  defp child_mount_basenames(%__MODULE__{mounts: mounts}, path) do
    prefix = if path == "/", do: "/", else: path <> "/"

    mounts
    |> Enum.filter(fn {mp, _mod, _state} ->
      mp != "/" and mp != path and String.starts_with?(mp, prefix)
    end)
    |> Enum.map(fn {mp, _mod, _state} ->
      # Strip the prefix and take the first path component
      rest = String.trim_leading(mp, prefix)
      rest |> String.split("/") |> hd()
    end)
    |> Enum.uniq()
  end

  # Returns true if a symlink target would cross a mount boundary.
  #
  # Absolute targets are resolved in user-facing coordinates. If the target
  # resolves to a different mount than the link, the symlink crosses a
  # boundary. Relative targets are resolved relative to the link's parent
  # directory in user-facing coordinates.
  defp symlink_crosses_mount?(%__MODULE__{} = fs, target, link_path, link_mount_idx) do
    user_facing_target =
      if String.starts_with?(target, "/") do
        normalize_path(target)
      else
        link_dir = dirname(normalize_path(link_path))
        resolve_path(link_dir, target)
      end

    {_mod, _state, _bp, target_idx} = resolve(fs, user_facing_target)
    target_idx != link_mount_idx
  end

  # Minimal synthetic stat for mountpoint directories.
  defp synthetic_dir_stat do
    %{
      is_file: false,
      is_directory: true,
      is_symbolic_link: false,
      mode: 0o755,
      size: 0,
      mtime: DateTime.utc_now()
    }
  end
end
