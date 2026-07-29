defmodule JustBash.FS.Memory do
  @moduledoc """
  JustBash's in-memory `VFS.Mountable` backend — the default backend
  mounted at `/` by `JustBash.FS.new/1`.

  ## Why not `VFS.Memory`?

  Not a legacy module, and deliberately not a delegate. `VFS.Mountable`
  is a ten-operation protocol shaped to virtual-FS semantics (git blobs,
  S3 objects, DB rows); vfs 0.1 intentionally cut `lstat`, `symlink`,
  `readlink`, `link`, `chmod`, and `append_file` from it, and its stock
  `VFS.Memory` backend stores bare `path => binary` pairs with no mode
  or symlink metadata (mtimes only, and not settable through write
  opts). Bash needs exactly what was cut: `ln`/`ln -s`, `readlink`,
  `chmod`, `test -L`, `ls -l` modes, and mtime-honoring writes. Those
  features require a richer entry model (file/directory/symlink entries
  carrying mode + mtime, with link resolution), which cannot be layered
  over `VFS.Memory`'s flat binary map — so this backend owns its own
  storage and implements the protocol against it.

  This module is the "real consumer" case the vfs SPEC anticipated: the
  ten universal operations are implemented in the `VFS.Mountable`
  `defimpl` below (reach them through the helpers on `VFS`), and the
  POSIX extensions are dispatched through the `JustBash.FS.POSIX`
  secondary protocol, which this backend implements natively and other
  backends refuse gracefully.

  Features beyond `VFS.Memory`:

  - Symbolic links (with loop detection on resolution)
  - Hard links
  - File permissions (mode)
  - Modification times

  All operations are pure: every mutation returns an updated struct.
  """

  alias VFS.Error
  alias VFS.Path, as: VPath
  alias VFS.Stat

  defstruct data: %{}

  @type file_entry :: %{
          type: :file,
          content: binary(),
          mode: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type directory_entry :: %{
          type: :directory,
          mode: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type symlink_entry :: %{
          type: :symlink,
          target: String.t(),
          mode: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type fs_entry :: file_entry() | directory_entry() | symlink_entry()

  @type t :: %__MODULE__{
          data: %{String.t() => fs_entry()}
        }

  @type write_opts :: [mode: non_neg_integer(), mtime: DateTime.t()]

  @doc """
  Create a new in-memory filesystem with optional initial files.

  Initial files can be provided as a map:
  - Simple form: `%{"/path/to/file" => "content"}`
  - Extended form: `%{"/path/to/file" => %{content: "content", mode: 0o755, mtime: ~U[...]}}`

  Parent directories are created automatically. Raises `ArgumentError`
  when the map is not realizable as a filesystem: either one entry's path
  runs through another (see `validate_initial_files!/1`), or an entry
  collides with a directory this backend already holds, as `%{"/" => "x"}`
  does.

  ## Examples

      iex> fs = JustBash.FS.Memory.new()
      iex> fs = JustBash.FS.Memory.new(%{"/home/user/file.txt" => "hello"})
      iex> fs = JustBash.FS.Memory.new(%{"/bin/script" => %{content: "#!/bin/bash", mode: 0o755}})
  """
  @spec new(map()) :: t()
  def new(initial_files \\ %{}) do
    validate_initial_files!(initial_files)

    fs = %__MODULE__{
      data: %{"/" => %{type: :directory, mode: 0o755, mtime: DateTime.utc_now()}}
    }

    Enum.reduce(initial_files, fs, fn {path, value}, acc ->
      case value do
        %{content: content} = init ->
          seed!(acc, path, content,
            mode: Map.get(init, :mode, 0o644),
            mtime: Map.get(init, :mtime, DateTime.utc_now())
          )

        content when is_binary(content) ->
          seed!(acc, path, content)
      end
    end)
  end

  # `validate_initial_files!/1` catches the map that is unrealizable on its
  # own terms; a seed can still collide with what the backend already holds
  # (`%{"/" => "x"}`). Both are caller mistakes at construction time, so
  # both raise `ArgumentError` rather than a `MatchError` from in here.
  defp seed!(fs, path, content, opts \\ []) do
    case write_file(fs, path, content, opts) do
      {:ok, new_fs} ->
        new_fs

      {:error, %Error{} = error} ->
        raise ArgumentError,
              "invalid initial files: cannot create #{inspect(path)}: " <>
                JustBash.FS.strerror(error)
    end
  end

  @doc """
  Validate an initial-files map before it is realized as a filesystem.

  A map like `%{"/m/j" => "x", "/m/j/a.md" => "y"}` describes a
  filesystem that cannot exist: `/m/j` is a regular file, so nothing can
  live under it. Seeding it anyway used to store an entry no directory
  listing could reach, and which one of the two entries won depended on
  map iteration order. Raise instead, naming both paths.
  """
  @spec validate_initial_files!(map()) :: :ok
  def validate_initial_files!(initial_files) do
    by_path =
      Map.new(initial_files, fn {path, _value} -> {normalize(path), path} end)

    case find_conflict(by_path) do
      nil ->
        :ok

      {ancestor, descendant} ->
        raise ArgumentError,
              "invalid initial files: #{inspect(ancestor)} is a regular file, so " <>
                "#{inspect(descendant)} cannot exist under it (POSIX path resolution " <>
                "fails with ENOTDIR). Drop one of the two entries."
    end
  end

  @doc """
  Write content to a file, creating it if it doesn't exist.

  Missing parent directories are created automatically. Accepts `:mode`
  and `:mtime` options; these also flow through `VFS.write_file/4` opts.

  Follows symlinks in every component (POSIX path resolution), including
  the final one (`O_TRUNC` semantics, matching `append_file/3`): the link
  survives and the target is replaced; writing to a dangling symlink
  creates the target. A non-final component that resolves to a regular
  file is `:enotdir`.
  """
  @spec write_file(t(), String.t(), binary(), write_opts()) ::
          {:ok, t()} | {:error, Error.t()}
  def write_file(%__MODULE__{} = fs, path, content, opts \\ []) do
    normalized = normalize(path)

    with {:ok, target_path} <- resolve_path(fs, normalized) do
      case Map.get(fs.data, target_path) do
        %{type: :directory} ->
          {:error, Error.new(:eisdir, path: normalized)}

        _ ->
          mode = Keyword.get(opts, :mode, 0o644)
          mtime = Keyword.get(opts, :mtime, DateTime.utc_now())

          fs = ensure_parent_dirs(fs, target_path)
          entry = %{type: :file, content: content, mode: mode, mtime: mtime}
          {:ok, %{fs | data: Map.put(fs.data, target_path, entry)}}
      end
    end
  end

  @doc """
  Get stat information for a path without following symlinks.

  A symlink reports `type: :symlink` with the target's byte size. Ancestor
  components still resolve — only the final one is left alone.
  """
  @spec lstat(t(), String.t()) :: {:ok, Stat.t(), t()} | {:error, Error.t()}
  def lstat(%__MODULE__{} = fs, path) do
    with {:ok, normalized} <- resolve_for_create(fs, normalize(path)) do
      case Map.get(fs.data, normalized) do
        nil ->
          {:error, Error.new(:enoent, path: normalized)}

        %{type: :symlink, target: target} = entry ->
          {:ok,
           %Stat{type: :symlink, size: byte_size(target), mtime: entry.mtime, mode: entry.mode},
           fs}

        entry ->
          {:ok, entry_stat(entry), fs}
      end
    end
  end

  @doc """
  Create a symbolic link at `link_path` pointing to `target`.

  The target is stored verbatim and resolved lazily on access, relative
  to the link's directory when not absolute. Absolute targets resolve
  within this backend's namespace (mount-local, chroot-like).
  """
  @spec symlink(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def symlink(%__MODULE__{} = fs, target, link_path) do
    with {:ok, normalized} <- resolve_for_create(fs, normalize(link_path)) do
      if Map.has_key?(fs.data, normalized) do
        {:error, Error.new(:eexist, path: normalized)}
      else
        fs = ensure_parent_dirs(fs, normalized)
        entry = %{type: :symlink, target: target, mode: 0o777, mtime: DateTime.utc_now()}
        {:ok, %{fs | data: Map.put(fs.data, normalized, entry)}}
      end
    end
  end

  @doc """
  Read the target of a symbolic link.

  Ancestor components resolve; the final one is the link being read.
  """
  @spec readlink(t(), String.t()) :: {:ok, String.t(), t()} | {:error, Error.t()}
  def readlink(%__MODULE__{} = fs, path) do
    with {:ok, normalized} <- resolve_for_create(fs, normalize(path)) do
      case Map.get(fs.data, normalized) do
        nil -> {:error, Error.new(:enoent, path: normalized)}
        %{type: :symlink, target: target} -> {:ok, target, fs}
        _ -> {:error, Error.new(:einval, path: normalized)}
      end
    end
  end

  @doc """
  Create a hard link. Only regular files can be hard-linked.

  Entries are immutable values, not shared inodes: the two names hold
  the same content at link time, but a later write or append through
  one name does not update the other. True hard-link aliasing would
  need inode indirection in the entry model.
  """
  @spec link(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def link(%__MODULE__{} = fs, existing_path, new_path) do
    with {:ok, new_norm} <- resolve_for_create(fs, normalize(new_path)),
         {:ok, existing_norm} <- resolve_for_create(fs, normalize(existing_path)) do
      do_link(fs, existing_norm, new_norm)
    end
  end

  defp do_link(%__MODULE__{data: data} = fs, existing_norm, new_norm) do
    cond do
      not Map.has_key?(data, existing_norm) ->
        {:error, Error.new(:enoent, path: existing_norm)}

      Map.get(data, existing_norm).type != :file ->
        {:error, Error.new(:eacces, path: existing_norm)}

      Map.has_key?(data, new_norm) ->
        {:error, Error.new(:eexist, path: new_norm)}

      true ->
        fs = ensure_parent_dirs(fs, new_norm)
        entry = Map.get(data, existing_norm)
        {:ok, %{fs | data: Map.put(fs.data, new_norm, entry)}}
    end
  end

  @doc """
  Change file/directory permissions.

  Follows symlinks to the final target (POSIX `chmod` semantics — there
  is no `lchmod` on Linux): the target's mode changes, the link entry
  keeps its conventional `0o777`.
  """
  @spec chmod(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def chmod(%__MODULE__{} = fs, path, mode) do
    normalized = normalize(path)

    with {:ok, target_path} <- resolve_path(fs, normalized) do
      case Map.get(fs.data, target_path) do
        nil ->
          {:error, Error.new(:enoent, path: normalized)}

        entry ->
          updated = %{entry | mode: mode}
          {:ok, %{fs | data: Map.put(fs.data, target_path, updated)}}
      end
    end
  end

  @doc """
  Append content to a file, creating it if it doesn't exist.

  Follows symlinks to the final target (POSIX `O_APPEND` semantics): the
  link survives and the target receives the bytes; appending to a
  dangling symlink creates the target. Preserves the file's existing
  mode, unlike a read+write composition. A non-final path component that
  resolves to a regular file is `:enotdir`.
  """
  @spec append_file(t(), String.t(), binary()) :: {:ok, t()} | {:error, Error.t()}
  def append_file(%__MODULE__{} = fs, path, content) do
    normalized = normalize(path)

    with {:ok, target_path} <- resolve_path(fs, normalized) do
      case Map.get(fs.data, target_path) do
        %{type: :directory} ->
          {:error, Error.new(:eisdir, path: normalized)}

        %{type: :file} = entry ->
          updated = %{entry | content: entry.content <> content, mtime: DateTime.utc_now()}
          {:ok, %{fs | data: Map.put(fs.data, target_path, updated)}}

        nil ->
          write_file(fs, target_path, content)
      end
    end
  end

  # ── shared internals (used by the Mountable defimpl below) ──────────────

  @doc false
  @spec __entry__(t(), String.t()) :: fs_entry() | nil
  def __entry__(%__MODULE__{data: data}, path), do: Map.get(data, path)

  @doc false
  @spec __resolve_entry__(t(), String.t()) :: {:ok, fs_entry()} | {:error, Error.t()}
  def __resolve_entry__(%__MODULE__{} = fs, path) do
    with {:ok, resolved} <- resolve_path(fs, normalize(path)) do
      case Map.get(fs.data, resolved) do
        nil -> {:error, Error.new(:enoent, path: resolved)}
        entry -> {:ok, entry}
      end
    end
  end

  @doc false
  @spec __resolve_for_read__(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def __resolve_for_read__(%__MODULE__{} = fs, path) do
    resolve_path(fs, normalize(path))
  end

  @doc false
  @spec __entry_stat__(fs_entry()) :: Stat.t()
  def __entry_stat__(entry), do: entry_stat(entry)

  @doc false
  @spec __normalize__(String.t()) :: String.t()
  def __normalize__(path), do: normalize(path)

  @doc false
  @spec __resolve_for_create__(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def __resolve_for_create__(%__MODULE__{} = fs, path) do
    resolve_for_create(fs, normalize(path))
  end

  # Tolerant normalization: unlike `VFS.Path.normalize/1`, accepts
  # relative and empty inputs by rooting them at "/". Backend-internal
  # paths have already been mount-stripped by the VFS dispatcher, so
  # they are absolute in practice; the tolerance matches the behavior
  # bash tests have always relied on for direct backend access.
  defp normalize(""), do: "/"
  defp normalize("/" <> _ = path), do: VPath.normalize(path)
  defp normalize(path), do: VPath.normalize("/" <> path)

  defp entry_stat(%{type: :file, content: content} = entry) do
    %Stat{type: :regular, size: byte_size(content), mtime: entry.mtime, mode: entry.mode}
  end

  defp entry_stat(%{type: :directory} = entry) do
    %Stat{type: :directory, size: 0, mtime: entry.mtime, mode: entry.mode}
  end

  defp ensure_parent_dirs(%__MODULE__{} = fs, path) do
    dir = VPath.dirname(path)

    cond do
      dir == "/" ->
        fs

      Map.has_key?(fs.data, dir) ->
        fs

      true ->
        fs = ensure_parent_dirs(fs, dir)
        entry = %{type: :directory, mode: 0o755, mtime: DateTime.utc_now()}
        %{fs | data: Map.put(fs.data, dir, entry)}
    end
  end

  # ── POSIX path resolution ────────────────────────────────────────────────
  #
  # A path resolves one component at a time from the root, following
  # symlinks as they are met. Every non-final component must resolve to a
  # directory or to nothing (writes create the missing intermediate
  # directories); one that resolves to a regular file is ENOTDIR, exactly
  # as the kernel reports it. Without that check a write stored an entry
  # underneath a regular file — readable by its path, yet unreachable from
  # any directory listing or `VFS.walk/3` (issue #53).
  #
  # Reads resolve the same way, and have to: if only writes followed
  # intermediate symlinks, a write through a symlinked directory would land
  # on the target and be invisible at the path the caller used — the same
  # unreachable-state bug mirrored, and quieter, because the write reports
  # success.
  #
  # One deviation remains, inherited from `normalize/1`: ".." is collapsed
  # lexically before resolution, so "/m/j/../k" never looks at "/m/j" and
  # cannot report ENOTDIR for it. Real resolution walks ".." through the
  # directory it lands in.

  # Symlink hops are budgeted, not remembered, matching Linux's
  # SYMLOOP_MAX. A set of visited links would reject legitimate paths that
  # cross the same link twice: with `/real/self -> /real`,
  # "/real/self/self/x" is two hops to "/real/x", not a cycle.
  @symloop_max 40

  # Reads and writes resolve identically, including a symlink at the final
  # component (O_TRUNC/O_APPEND/chmod semantics, where the link is written
  # through). They differ only in what the caller does with a resolved path
  # that holds nothing: a write creates it, a read reports ENOENT.
  @spec resolve_path(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  defp resolve_path(%__MODULE__{} = fs, path) do
    walk(fs, "/", components(path), @symloop_max, :follow_final)
  end

  # Resolve every component *except* the final one, which is taken
  # literally: mkdir/symlink/link semantics, where an existing final
  # component is EEXIST rather than a link to follow, and lstat/readlink/rm
  # semantics, where the link itself is the subject.
  @spec resolve_for_create(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  defp resolve_for_create(%__MODULE__{} = fs, path) do
    walk(fs, "/", components(path), @symloop_max, :keep_final)
  end

  defp components("/"), do: []
  defp components("/" <> rest), do: String.split(rest, "/")

  # `parent` is the resolved prefix walked so far; splitting once and
  # descending with it keeps resolution a single pass, rather than taking
  # the path apart with dirname/basename at every level.
  defp walk(_fs, resolved, [], _hops, _final), do: {:ok, resolved}

  defp walk(%__MODULE__{data: data} = fs, parent, [component | rest], hops, final) do
    candidate = join_child(parent, component)

    case Map.get(data, candidate) do
      %{type: :symlink, target: target} when rest != [] or final == :follow_final ->
        follow(fs, candidate, target, rest, hops, final)

      %{type: :file} when rest != [] ->
        {:error, Error.new(:enotdir, path: candidate)}

      # A directory, nothing at all (a write creates it), or the final
      # component of a `:keep_final` resolution.
      _ ->
        walk(fs, candidate, rest, hops, final)
    end
  end

  defp follow(_fs, candidate, _target, _rest, 0, _final) do
    {:error, Error.new(:eloop, path: candidate)}
  end

  defp follow(%__MODULE__{} = fs, candidate, target, rest, hops, final) do
    target_components = candidate |> resolve_symlink_target(target) |> components()
    walk(fs, "/", target_components ++ rest, hops - 1, final)
  end

  defp join_child("/", child), do: "/" <> child
  defp join_child(parent, child), do: parent <> "/" <> child

  # An initial-files entry conflicts when another entry is one of its
  # ancestors: that ancestor is a regular file, so the deeper path cannot
  # exist. Checking ancestors (rather than string prefixes) keeps
  # "/m/jj" and "/m/j" independent.
  defp find_conflict(by_path) do
    Enum.find_value(by_path, fn {path, original} ->
      path
      |> ancestors()
      |> Enum.find_value(fn ancestor ->
        case Map.fetch(by_path, ancestor) do
          {:ok, ancestor_original} -> {ancestor_original, original}
          :error -> nil
        end
      end)
    end)
  end

  defp ancestors("/"), do: []

  defp ancestors(path) do
    parent = VPath.dirname(path)
    if parent == "/", do: [], else: [parent | ancestors(parent)]
  end

  defp resolve_symlink_target(symlink_path, target) do
    if String.starts_with?(target, "/") do
      normalize(target)
    else
      VPath.join(VPath.dirname(symlink_path), target)
    end
  end
end

defimpl VFS.Mountable, for: JustBash.FS.Memory do
  use VFS.Skeleton

  alias JustBash.FS.Memory
  alias VFS.Error

  # `exists?` resolves ancestors but not the final component, so a dangling
  # symlink still exists (as the link).
  def exists?(%Memory{} = fs, path) do
    case Memory.__resolve_for_create__(fs, path) do
      {:ok, resolved} -> {Map.has_key?(fs.data, resolved), fs}
      {:error, _error} -> {false, fs}
    end
  end

  def stat(%Memory{} = fs, path) do
    case Memory.__resolve_entry__(fs, path) do
      {:ok, entry} -> {:ok, Memory.__entry_stat__(entry), fs}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def readdir(%Memory{data: data} = fs, path) do
    with {:ok, normalized} <- Memory.__resolve_for_read__(fs, path) do
      case Map.get(data, normalized) do
        nil ->
          {:error, Error.new(:enoent, path: normalized)}

        %{type: type} when type != :directory ->
          {:error, Error.new(:enotdir, path: normalized)}

        %{type: :directory} ->
          prefix = if normalized == "/", do: "/", else: normalized <> "/"

          entries =
            data
            |> Map.keys()
            |> Enum.filter(fn p -> p != normalized and String.starts_with?(p, prefix) end)
            |> Enum.map(fn p ->
              rest = String.replace_prefix(p, prefix, "")
              rest |> String.split("/", parts: 2) |> hd()
            end)
            |> Enum.uniq()
            |> Enum.sort()

          {:ok, entries, fs}
      end
    end
  end

  def stream_read(%Memory{} = fs, path, opts) do
    case Memory.__resolve_entry__(fs, path) do
      {:ok, %{type: :file, content: content}} ->
        case VFS.StreamOptions.apply(content, opts) do
          {:ok, stream} -> {:ok, stream, fs}
          {:error, kind} -> {:error, Error.new(kind, path: Memory.__normalize__(path))}
        end

      {:ok, %{type: :directory}} ->
        {:error, Error.new(:eisdir, path: Memory.__normalize__(path))}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def write_file(%Memory{} = fs, path, content, opts) do
    Memory.write_file(fs, path, content, opts)
  end

  # Every ancestor must resolve to a directory (or to nothing, when
  # `parents: true` will create it); an ancestor that is a regular file is
  # ENOTDIR, and `mkdir -p` must refuse rather than bury the new directory
  # under it.
  def mkdir(%Memory{} = fs, path, opts) do
    with {:ok, resolved} <- Memory.__resolve_for_create__(fs, path) do
      do_mkdir_resolved(fs, resolved, Keyword.get(opts, :parents, false))
    end
  end

  # Ancestors resolve, the final component does not: `rm /link` unlinks the
  # symlink, it does not touch what the link points at.
  def rm(%Memory{data: data} = fs, path, opts) do
    recursive? = Keyword.get(opts, :recursive, false)

    with {:ok, normalized} <- Memory.__resolve_for_create__(fs, path) do
      case Map.get(data, normalized) do
        nil ->
          {:error, Error.new(:enoent, path: normalized)}

        %{type: :directory} ->
          rm_directory(fs, normalized, recursive?)

        _ ->
          {:ok, %{fs | data: Map.delete(data, normalized)}}
      end
    end
  end

  def capabilities(_), do: MapSet.new([:read, :write, :mkdir])

  # ── helpers ──

  defp do_mkdir_resolved(%Memory{data: data} = fs, normalized, parents?) do
    case Map.get(data, normalized) do
      %{type: type} when type != :directory ->
        {:error, Error.new(:eexist, path: normalized)}

      %{type: :directory} when not parents? ->
        {:error, Error.new(:eexist, path: normalized)}

      %{type: :directory} ->
        {:ok, fs}

      nil ->
        mkdir_with_parent(fs, normalized, parents?)
    end
  end

  defp mkdir_with_parent(%Memory{data: data} = fs, normalized, parents?) do
    parent = VFS.Path.dirname(normalized)
    parent_exists = parent == "/" or Map.has_key?(data, parent)

    case {parent_exists, parents?} do
      {false, false} ->
        {:error, Error.new(:enoent, path: normalized)}

      # The whole chain was already resolved by the outer `mkdir/3`. Going
      # back through the protocol would re-resolve it once per level, which
      # is O(depth^2) resolutions for a single `mkdir -p`.
      {false, true} ->
        with {:ok, fs} <- do_mkdir_resolved(fs, parent, true) do
          do_mkdir(fs, normalized)
        end

      {true, _} ->
        do_mkdir(fs, normalized)
    end
  end

  defp do_mkdir(%Memory{} = fs, normalized) do
    entry = %{type: :directory, mode: 0o755, mtime: DateTime.utc_now()}
    {:ok, %{fs | data: Map.put(fs.data, normalized, entry)}}
  end

  defp rm_directory(%Memory{data: data} = fs, normalized, recursive?) do
    prefix = if normalized == "/", do: "/", else: normalized <> "/"
    children? = Enum.any?(Map.keys(data), &(&1 != normalized and String.starts_with?(&1, prefix)))

    cond do
      not children? ->
        {:ok, %{fs | data: Map.delete(data, normalized)}}

      recursive? ->
        pruned =
          Map.reject(data, fn {k, _} ->
            k == normalized or String.starts_with?(k, prefix)
          end)

        {:ok, %{fs | data: pruned}}

      true ->
        {:error, Error.new(:enotempty, path: normalized)}
    end
  end
end
