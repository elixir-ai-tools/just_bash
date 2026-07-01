defmodule JustBash.FS.Memory do
  @moduledoc """
  JustBash's in-memory `VFS.Mountable` backend.

  This is the default backend mounted at `/` by `JustBash.FS.new/1`. It
  extends plain in-memory storage (see `VFS.Memory`) with the POSIX
  features bash scripts rely on:

  - Symbolic links (with loop detection on resolution)
  - Hard links
  - File permissions (mode)
  - Modification times

  The ten universal filesystem operations are reached through the
  `VFS.Mountable` protocol (use the helpers on `VFS`). The POSIX
  extensions — `lstat/2`, `symlink/3`, `readlink/2`, `link/3`, `chmod/3`,
  `append_file/3` — are deliberately *not* part of that protocol (see the
  vfs design notes); they are dispatched through `JustBash.FS.POSIX`,
  which this backend implements natively.

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

  Parent directories are created automatically.

  ## Examples

      iex> fs = JustBash.FS.Memory.new()
      iex> fs = JustBash.FS.Memory.new(%{"/home/user/file.txt" => "hello"})
      iex> fs = JustBash.FS.Memory.new(%{"/bin/script" => %{content: "#!/bin/bash", mode: 0o755}})
  """
  @spec new(map()) :: t()
  def new(initial_files \\ %{}) do
    fs = %__MODULE__{
      data: %{"/" => %{type: :directory, mode: 0o755, mtime: DateTime.utc_now()}}
    }

    Enum.reduce(initial_files, fs, fn {path, value}, acc ->
      case value do
        %{content: content} = init ->
          {:ok, new_fs} =
            write_file(acc, path, content,
              mode: Map.get(init, :mode, 0o644),
              mtime: Map.get(init, :mtime, DateTime.utc_now())
            )

          new_fs

        content when is_binary(content) ->
          {:ok, new_fs} = write_file(acc, path, content)
          new_fs
      end
    end)
  end

  @doc """
  Write content to a file, creating it if it doesn't exist.

  Parent directories are created automatically. Accepts `:mode` and
  `:mtime` options; these also flow through `VFS.write_file/4` opts.
  """
  @spec write_file(t(), String.t(), binary(), write_opts()) ::
          {:ok, t()} | {:error, Error.t()}
  def write_file(%__MODULE__{} = fs, path, content, opts \\ []) do
    normalized = normalize(path)

    case Map.get(fs.data, normalized) do
      %{type: :directory} ->
        {:error, Error.new(:eisdir, path: normalized)}

      _ ->
        mode = Keyword.get(opts, :mode, 0o644)
        mtime = Keyword.get(opts, :mtime, DateTime.utc_now())

        fs = ensure_parent_dirs(fs, normalized)
        entry = %{type: :file, content: content, mode: mode, mtime: mtime}
        {:ok, %{fs | data: Map.put(fs.data, normalized, entry)}}
    end
  end

  @doc """
  Get stat information for a path without following symlinks.

  A symlink reports `type: :symlink` with the target's byte size.
  """
  @spec lstat(t(), String.t()) :: {:ok, Stat.t(), t()} | {:error, Error.t()}
  def lstat(%__MODULE__{data: data} = fs, path) do
    normalized = normalize(path)

    case Map.get(data, normalized) do
      nil ->
        {:error, Error.new(:enoent, path: normalized)}

      %{type: :symlink, target: target} = entry ->
        {:ok,
         %Stat{type: :symlink, size: byte_size(target), mtime: entry.mtime, mode: entry.mode}, fs}

      entry ->
        {:ok, entry_stat(entry), fs}
    end
  end

  @doc """
  Create a symbolic link at `link_path` pointing to `target`.

  The target is stored verbatim and resolved lazily on access, relative
  to the link's directory when not absolute. Absolute targets resolve
  within this backend's namespace (mount-local, chroot-like).
  """
  @spec symlink(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def symlink(%__MODULE__{data: data} = fs, target, link_path) do
    normalized = normalize(link_path)

    if Map.has_key?(data, normalized) do
      {:error, Error.new(:eexist, path: normalized)}
    else
      fs = ensure_parent_dirs(fs, normalized)
      entry = %{type: :symlink, target: target, mode: 0o777, mtime: DateTime.utc_now()}
      {:ok, %{fs | data: Map.put(fs.data, normalized, entry)}}
    end
  end

  @doc """
  Read the target of a symbolic link.
  """
  @spec readlink(t(), String.t()) :: {:ok, String.t(), t()} | {:error, Error.t()}
  def readlink(%__MODULE__{data: data} = fs, path) do
    normalized = normalize(path)

    case Map.get(data, normalized) do
      nil -> {:error, Error.new(:enoent, path: normalized)}
      %{type: :symlink, target: target} -> {:ok, target, fs}
      _ -> {:error, Error.new(:einval, path: normalized)}
    end
  end

  @doc """
  Create a hard link. Only regular files can be hard-linked.
  """
  @spec link(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def link(%__MODULE__{data: data} = fs, existing_path, new_path) do
    existing_norm = normalize(existing_path)
    new_norm = normalize(new_path)

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
  """
  @spec chmod(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def chmod(%__MODULE__{data: data} = fs, path, mode) do
    normalized = normalize(path)

    case Map.get(data, normalized) do
      nil ->
        {:error, Error.new(:enoent, path: normalized)}

      entry ->
        updated = %{entry | mode: mode}
        {:ok, %{fs | data: Map.put(data, normalized, updated)}}
    end
  end

  @doc """
  Append content to a file, creating it if it doesn't exist.

  Follows symlinks to the final target (POSIX `O_APPEND` semantics): the
  link survives and the target receives the bytes; appending to a
  dangling symlink creates the target. Preserves the file's existing
  mode, unlike a read+write composition.
  """
  @spec append_file(t(), String.t(), binary()) :: {:ok, t()} | {:error, Error.t()}
  def append_file(%__MODULE__{} = fs, path, content) do
    normalized = normalize(path)

    case resolve_final_path(fs, normalized, MapSet.new()) do
      {:error, :eloop} ->
        {:error, Error.new(:eloop, path: normalized)}

      {:ok, target_path} ->
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
  @spec __resolve_entry__(t(), String.t()) ::
          {:ok, fs_entry()} | {:error, :enoent | :eloop}
  def __resolve_entry__(%__MODULE__{} = fs, path) do
    do_resolve_entry(fs, normalize(path), MapSet.new())
  end

  @doc false
  @spec __entry_stat__(fs_entry()) :: Stat.t()
  def __entry_stat__(entry), do: entry_stat(entry)

  @doc false
  @spec __normalize__(String.t()) :: String.t()
  def __normalize__(path), do: normalize(path)

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

  @dialyzer {:nowarn_function, do_resolve_entry: 3}
  defp do_resolve_entry(%__MODULE__{data: data} = fs, path, seen) do
    case Map.get(data, path) do
      nil ->
        {:error, :enoent}

      %{type: :symlink, target: target} ->
        if MapSet.member?(seen, path) do
          {:error, :eloop}
        else
          resolved = resolve_symlink_target(path, target)
          do_resolve_entry(fs, resolved, MapSet.put(seen, path))
        end

      entry ->
        {:ok, entry}
    end
  end

  # Walk a symlink chain to the final (non-symlink) path. A missing entry
  # terminates the walk with the path it would occupy — that is where an
  # append through a dangling link creates the file.
  @dialyzer {:nowarn_function, resolve_final_path: 3}
  defp resolve_final_path(%__MODULE__{data: data} = fs, path, seen) do
    case Map.get(data, path) do
      %{type: :symlink, target: target} ->
        if MapSet.member?(seen, path) do
          {:error, :eloop}
        else
          resolved = resolve_symlink_target(path, target)
          resolve_final_path(fs, resolved, MapSet.put(seen, path))
        end

      _ ->
        {:ok, path}
    end
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

  def exists?(%Memory{} = fs, path) do
    {Map.has_key?(fs.data, Memory.__normalize__(path)), fs}
  end

  def stat(%Memory{} = fs, path) do
    normalized = Memory.__normalize__(path)

    case Memory.__resolve_entry__(fs, normalized) do
      {:ok, entry} -> {:ok, Memory.__entry_stat__(entry), fs}
      {:error, kind} -> {:error, Error.new(kind, path: normalized)}
    end
  end

  def readdir(%Memory{data: data} = fs, path) do
    normalized = Memory.__normalize__(path)

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

  def stream_read(%Memory{} = fs, path, opts) do
    normalized = Memory.__normalize__(path)

    case Memory.__resolve_entry__(fs, normalized) do
      {:ok, %{type: :file, content: content}} ->
        case VFS.StreamOptions.apply(content, opts) do
          {:ok, stream} -> {:ok, stream, fs}
          {:error, kind} -> {:error, Error.new(kind, path: normalized)}
        end

      {:ok, %{type: :directory}} ->
        {:error, Error.new(:eisdir, path: normalized)}

      {:error, kind} ->
        {:error, Error.new(kind, path: normalized)}
    end
  end

  def write_file(%Memory{} = fs, path, content, opts) do
    Memory.write_file(fs, path, content, opts)
  end

  def mkdir(%Memory{data: data} = fs, path, opts) do
    normalized = Memory.__normalize__(path)
    parents? = Keyword.get(opts, :parents, false)

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

  def rm(%Memory{data: data} = fs, path, opts) do
    normalized = Memory.__normalize__(path)
    recursive? = Keyword.get(opts, :recursive, false)

    case Map.get(data, normalized) do
      nil ->
        {:error, Error.new(:enoent, path: normalized)}

      %{type: :directory} ->
        rm_directory(fs, normalized, recursive?)

      _ ->
        {:ok, %{fs | data: Map.delete(data, normalized)}}
    end
  end

  def capabilities(_), do: MapSet.new([:read, :write, :mkdir])

  # ── helpers ──

  defp mkdir_with_parent(%Memory{data: data} = fs, normalized, parents?) do
    parent = VFS.Path.dirname(normalized)
    parent_exists = parent == "/" or Map.has_key?(data, parent)

    case {parent_exists, parents?} do
      {false, false} ->
        {:error, Error.new(:enoent, path: normalized)}

      {false, true} ->
        {:ok, fs} = mkdir(fs, parent, parents: true)
        do_mkdir(fs, normalized)

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
