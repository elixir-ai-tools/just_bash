defmodule JustBash.Fs.InMemoryFs do
  @moduledoc """
  In-memory filesystem implementation for JustBash.

  Provides a complete virtual filesystem with support for:
  - Files (with binary content)
  - Directories
  - Symbolic links
  - File permissions (mode)
  - Modification times

  All operations are synchronous and work on an in-memory data structure.
  """

  @behaviour JustBash.Fs.Backend

  alias JustBash.Fs

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

  @type stat_result :: %{
          is_file: boolean(),
          is_directory: boolean(),
          is_symbolic_link: boolean(),
          mode: non_neg_integer(),
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type t :: %__MODULE__{
          data: %{String.t() => fs_entry()}
        }

  @type mkdir_opts :: [recursive: boolean()]
  @type rm_opts :: [recursive: boolean(), force: boolean()]
  @type cp_opts :: [recursive: boolean()]
  @type write_opts :: [mode: non_neg_integer(), mtime: DateTime.t()]

  @doc """
  Create a new in-memory filesystem with optional initial files.

  ## Options

  Initial files can be provided as a map:
  - Simple form: `%{"/path/to/file" => "content"}`
  - Extended form: `%{"/path/to/file" => %{content: "content", mode: 0o755, mtime: ~U[...]}}`

  ## Examples

      iex> fs = InMemoryFs.new()
      iex> fs = InMemoryFs.new(%{"/home/user/file.txt" => "hello"})
      iex> fs = InMemoryFs.new(%{"/bin/script" => %{content: "#!/bin/bash", mode: 0o755}})
  """
  @spec new(map()) :: t()
  def new(initial_files \\ %{}) do
    fs = %__MODULE__{
      data: %{"/" => %{type: :directory, mode: 0o755, mtime: DateTime.utc_now()}}
    }

    Enum.reduce(initial_files, fs, fn {path, value}, acc ->
      case value do
        %{content: content} = init ->
          write_file(acc, path, content,
            mode: Map.get(init, :mode, 0o644),
            mtime: Map.get(init, :mtime, DateTime.utc_now())
          )
          |> elem(1)

        content when is_binary(content) ->
          {:ok, new_fs} = write_file(acc, path, content)
          new_fs
      end
    end)
  end

  @doc """
  Normalize a filesystem path.

  Delegates to `JustBash.Fs.normalize_path/1`.
  """
  @deprecated "Use JustBash.Fs.normalize_path/1 instead"
  @spec normalize_path(String.t()) :: String.t()
  defdelegate normalize_path(path), to: Fs

  @doc """
  Get the directory name (parent path) of a path.

  Delegates to `JustBash.Fs.dirname/1`.
  """
  @deprecated "Use JustBash.Fs.dirname/1 instead"
  @spec dirname(String.t()) :: String.t()
  defdelegate dirname(path), to: Fs

  @doc """
  Get the base name (file name) of a path.

  Delegates to `JustBash.Fs.basename/1`.
  """
  @deprecated "Use JustBash.Fs.basename/1 instead"
  @spec basename(String.t()) :: String.t()
  defdelegate basename(path), to: Fs

  @doc """
  Resolve a path relative to a base path.

  Delegates to `JustBash.Fs.resolve_path/2`.
  """
  @deprecated "Use JustBash.Fs.resolve_path/2 instead"
  @spec resolve_path(String.t(), String.t()) :: String.t()
  defdelegate resolve_path(base, path), to: Fs

  @doc """
  Check if a path exists in the filesystem.

  ## Examples

      iex> fs = InMemoryFs.new(%{"/file.txt" => "hello"})
      iex> InMemoryFs.exists?(fs, "/file.txt")
      true
      iex> InMemoryFs.exists?(fs, "/nonexistent")
      false
  """
  @impl true
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{data: data}, path) do
    Map.has_key?(data, Fs.normalize_path(path))
  end

  @doc """
  Get the stat information for a path (follows symlinks).

  ## Returns

  `{:ok, stat}` with stat containing:
  - `:is_file` - boolean
  - `:is_directory` - boolean
  - `:is_symbolic_link` - always false (stat follows symlinks)
  - `:mode` - file permissions
  - `:size` - byte size (0 for directories)
  - `:mtime` - modification time

  ## Errors

  - `{:error, :enoent}` - path does not exist
  """
  @impl true
  @spec stat(t(), String.t()) :: {:ok, stat_result()} | {:error, :enoent}
  def stat(%__MODULE__{} = fs, path) do
    normalized = Fs.normalize_path(path)

    case get_entry_following_symlinks(fs, normalized) do
      {:ok, entry} ->
        size =
          case entry do
            %{type: :file, content: content} -> byte_size(content)
            _ -> 0
          end

        {:ok,
         %{
           is_file: entry.type == :file,
           is_directory: entry.type == :directory,
           is_symbolic_link: false,
           mode: entry.mode,
           size: size,
           mtime: entry.mtime
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Get the stat information for a path (does NOT follow symlinks).
  """
  @impl true
  @spec lstat(t(), String.t()) :: {:ok, stat_result()} | {:error, :enoent}
  def lstat(%__MODULE__{data: data}, path) do
    normalized = Fs.normalize_path(path)

    case Map.get(data, normalized) do
      nil ->
        {:error, :enoent}

      %{type: :symlink, target: target} = entry ->
        {:ok,
         %{
           is_file: false,
           is_directory: false,
           is_symbolic_link: true,
           mode: entry.mode,
           size: byte_size(target),
           mtime: entry.mtime
         }}

      entry ->
        size =
          case entry do
            %{type: :file, content: content} -> byte_size(content)
            _ -> 0
          end

        {:ok,
         %{
           is_file: entry.type == :file,
           is_directory: entry.type == :directory,
           is_symbolic_link: false,
           mode: entry.mode,
           size: size,
           mtime: entry.mtime
         }}
    end
  end

  @doc """
  Read the contents of a file.

  ## Returns

  - `{:ok, content}` - binary content of the file
  - `{:error, :enoent}` - file does not exist
  - `{:error, :eisdir}` - path is a directory
  - `{:error, :eloop}` - too many symlink levels
  """
  @impl true
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, :enoent | :eisdir | :eloop}
  def read_file(%__MODULE__{} = fs, path) do
    normalized = Fs.normalize_path(path)

    case get_entry_following_symlinks(fs, normalized) do
      {:ok, %{type: :file, content: content}} ->
        {:ok, content}

      {:ok, %{type: :directory}} ->
        {:error, :eisdir}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Write content to a file, creating it if it doesn't exist.

  Parent directories are created automatically.

  ## Options

  - `:mode` - file permissions (default: 0o644)
  - `:mtime` - modification time (default: now)

  ## Returns

  - `{:ok, updated_fs}` on success
  - `{:error, :eisdir}` if path is a directory
  """
  @spec write_file(t(), String.t(), binary()) :: {:ok, t()} | {:error, :eisdir}
  def write_file(fs, path, content), do: write_file(fs, path, content, [])

  @impl true
  @spec write_file(t(), String.t(), binary(), write_opts()) ::
          {:ok, t()} | {:error, :eisdir}
  def write_file(%__MODULE__{} = fs, path, content, opts) do
    normalized = Fs.normalize_path(path)

    case Map.get(fs.data, normalized) do
      %{type: :directory} ->
        {:error, :eisdir}

      _ ->
        mode = Keyword.get(opts, :mode, 0o644)
        mtime = Keyword.get(opts, :mtime, DateTime.utc_now())

        fs = ensure_parent_dirs(fs, normalized)

        entry = %{
          type: :file,
          content: content,
          mode: mode,
          mtime: mtime
        }

        {:ok, %{fs | data: Map.put(fs.data, normalized, entry)}}
    end
  end

  @doc """
  Append content to a file, creating it if it doesn't exist.
  """
  @impl true
  @spec append_file(t(), String.t(), binary()) :: {:ok, t()} | {:error, :eisdir}
  def append_file(%__MODULE__{} = fs, path, content) do
    normalized = Fs.normalize_path(path)

    case Map.get(fs.data, normalized) do
      %{type: :directory} ->
        {:error, :eisdir}

      %{type: :file} = entry ->
        new_content = entry.content <> content
        updated_entry = %{entry | content: new_content, mtime: DateTime.utc_now()}
        {:ok, %{fs | data: Map.put(fs.data, normalized, updated_entry)}}

      nil ->
        write_file(fs, path, content)
    end
  end

  @doc """
  Create a directory.

  ## Options

  - `:recursive` - create parent directories if needed (default: false)

  ## Returns

  - `{:ok, updated_fs}` on success
  - `{:error, :eexist}` if path already exists (and not recursive with existing dir)
  - `{:error, :enoent}` if parent doesn't exist (and not recursive)
  """
  @spec mkdir(t(), String.t()) :: {:ok, t()} | {:error, :eexist | :enoent}
  def mkdir(fs, path), do: mkdir(fs, path, [])

  @impl true
  @spec mkdir(t(), String.t(), mkdir_opts()) :: {:ok, t()} | {:error, :eexist | :enoent}
  def mkdir(%__MODULE__{data: data} = fs, path, opts) do
    normalized = Fs.normalize_path(path)
    recursive = Keyword.get(opts, :recursive, false)

    case Map.get(data, normalized) do
      %{type: :file} ->
        {:error, :eexist}

      %{type: :directory} when not recursive ->
        {:error, :eexist}

      %{type: :directory} ->
        {:ok, fs}

      nil ->
        mkdir_with_parent(fs, data, normalized, recursive)
    end
  end

  defp mkdir_with_parent(fs, data, normalized, recursive) do
    parent = Fs.dirname(normalized)
    parent_exists = parent == "/" or Map.has_key?(data, parent)

    case {parent_exists, recursive} do
      {false, false} ->
        {:error, :enoent}

      {false, true} ->
        {:ok, fs} = mkdir(fs, parent, recursive: true)
        do_mkdir(fs, normalized)

      {true, _} ->
        do_mkdir(fs, normalized)
    end
  end

  defp do_mkdir(%__MODULE__{} = fs, normalized) do
    entry = %{type: :directory, mode: 0o755, mtime: DateTime.utc_now()}
    {:ok, %{fs | data: Map.put(fs.data, normalized, entry)}}
  end

  @doc """
  Read directory contents.

  ## Returns

  - `{:ok, entries}` - list of entry names (not full paths), sorted
  - `{:error, :enoent}` - directory does not exist
  - `{:error, :enotdir}` - path is not a directory
  """
  @impl true
  @spec readdir(t(), String.t()) :: {:ok, [String.t()]} | {:error, :enoent | :enotdir}
  def readdir(%__MODULE__{data: data}, path) do
    normalized = Fs.normalize_path(path)

    case Map.get(data, normalized) do
      nil ->
        {:error, :enoent}

      %{type: type} when type != :directory ->
        {:error, :enotdir}

      %{type: :directory} ->
        prefix = if normalized == "/", do: "/", else: normalized <> "/"

        entries =
          data
          |> Map.keys()
          |> Enum.filter(fn p ->
            p != normalized and String.starts_with?(p, prefix)
          end)
          |> Enum.map(fn p ->
            rest = String.slice(p, String.length(prefix)..-1//1)
            rest |> String.split("/") |> hd()
          end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, entries}
    end
  end

  @doc """
  Remove a file or directory.

  ## Options

  - `:recursive` - remove directory contents recursively (default: false)
  - `:force` - don't error if path doesn't exist (default: false)

  ## Returns

  - `{:ok, updated_fs}` on success
  - `{:error, :enoent}` if path doesn't exist (and not force)
  - `{:error, :enotempty}` if directory has contents (and not recursive)
  """
  @spec rm(t(), String.t()) :: {:ok, t()} | {:error, :enoent | :enotempty}
  def rm(fs, path), do: rm(fs, path, [])

  @impl true
  @spec rm(t(), String.t(), rm_opts()) :: {:ok, t()} | {:error, :enoent | :enotempty}
  def rm(%__MODULE__{data: data} = fs, path, opts) do
    normalized = Fs.normalize_path(path)
    recursive = Keyword.get(opts, :recursive, false)
    force = Keyword.get(opts, :force, false)

    case Map.get(data, normalized) do
      nil when force ->
        {:ok, fs}

      nil ->
        {:error, :enoent}

      %{type: :directory} ->
        case readdir(fs, normalized) do
          {:ok, []} ->
            {:ok, %{fs | data: Map.delete(data, normalized)}}

          {:ok, children} when recursive ->
            rm_children_and_dir(fs, normalized, children, opts)

          {:ok, _} ->
            {:error, :enotempty}
        end

      _ ->
        {:ok, %{fs | data: Map.delete(data, normalized)}}
    end
  end

  defp rm_children_and_dir(fs, normalized, children, opts) do
    fs =
      Enum.reduce(children, fs, fn child, acc_fs ->
        child_path = join_path(normalized, child)
        {:ok, new_fs} = rm(acc_fs, child_path, opts)
        new_fs
      end)

    {:ok, %{fs | data: Map.delete(fs.data, normalized)}}
  end

  @doc """
  Copy a file or directory.

  ## Options

  - `:recursive` - copy directory contents recursively (required for directories)

  ## Returns

  - `{:ok, updated_fs}` on success
  - `{:error, :enoent}` if source doesn't exist
  - `{:error, :eisdir}` if source is directory and not recursive
  """
  @spec cp(t(), String.t(), String.t(), cp_opts()) ::
          {:ok, t()} | {:error, :enoent | :eisdir | :enotdir}
  def cp(%__MODULE__{data: data} = fs, src, dest, opts \\ []) do
    src_norm = Fs.normalize_path(src)
    dest_norm = Fs.normalize_path(dest)
    recursive = Keyword.get(opts, :recursive, false)

    case Map.get(data, src_norm) do
      nil ->
        {:error, :enoent}

      %{type: :file} = entry ->
        fs = ensure_parent_dirs(fs, dest_norm)
        {:ok, %{fs | data: Map.put(fs.data, dest_norm, entry)}}

      %{type: :symlink} = entry ->
        fs = ensure_parent_dirs(fs, dest_norm)
        {:ok, %{fs | data: Map.put(fs.data, dest_norm, entry)}}

      %{type: :directory} when not recursive ->
        {:error, :eisdir}

      %{type: :directory} ->
        case mkdir(fs, dest_norm, recursive: true) do
          {:ok, fs} ->
            cp_children(fs, src_norm, dest_norm, opts)

          {:error, :eexist} ->
            {:error, :enotdir}

          {:error, _} = err ->
            err
        end
    end
  end

  defp cp_children(fs, src_norm, dest_norm, opts) do
    {:ok, children} = readdir(fs, src_norm)

    Enum.reduce(children, {:ok, fs}, fn child, {:ok, acc_fs} ->
      src_child = join_path(src_norm, child)
      dest_child = join_path(dest_norm, child)
      cp(acc_fs, src_child, dest_child, opts)
    end)
  end

  defp join_path("/", child), do: "/" <> child
  defp join_path(parent, child), do: parent <> "/" <> child

  @doc """
  Move/rename a file or directory.
  """
  @spec mv(t(), String.t(), String.t()) :: {:ok, t()} | {:error, :enoent | :eisdir | :enotdir}
  def mv(%__MODULE__{} = fs, src, dest) do
    src_norm = Fs.normalize_path(src)
    dest_norm = Fs.normalize_path(dest)

    if src_norm == dest_norm do
      {:ok, fs}
    else
      case cp(fs, src_norm, dest_norm, recursive: true) do
        {:ok, fs} -> rm(fs, src_norm, recursive: true)
        error -> error
      end
    end
  end

  @doc """
  Change file/directory permissions.
  """
  @impl true
  @spec chmod(t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, :enoent}
  def chmod(%__MODULE__{data: data} = fs, path, mode) do
    normalized = Fs.normalize_path(path)

    case Map.get(data, normalized) do
      nil ->
        {:error, :enoent}

      entry ->
        updated = %{entry | mode: mode}
        {:ok, %{fs | data: Map.put(data, normalized, updated)}}
    end
  end

  @doc """
  Create a symbolic link.
  """
  @impl true
  @spec symlink(t(), String.t(), String.t()) :: {:ok, t()} | {:error, :eexist}
  def symlink(%__MODULE__{data: data} = fs, target, link_path) do
    normalized = Fs.normalize_path(link_path)

    if Map.has_key?(data, normalized) do
      {:error, :eexist}
    else
      fs = ensure_parent_dirs(fs, normalized)

      entry = %{
        type: :symlink,
        target: target,
        mode: 0o777,
        mtime: DateTime.utc_now()
      }

      {:ok, %{fs | data: Map.put(fs.data, normalized, entry)}}
    end
  end

  @doc """
  Read the target of a symbolic link.
  """
  @impl true
  @spec readlink(t(), String.t()) :: {:ok, String.t()} | {:error, :enoent | :einval}
  def readlink(%__MODULE__{data: data}, path) do
    normalized = Fs.normalize_path(path)

    case Map.get(data, normalized) do
      nil -> {:error, :enoent}
      %{type: :symlink, target: target} -> {:ok, target}
      _ -> {:error, :einval}
    end
  end

  @doc """
  Create a hard link.
  """
  @impl true
  @spec link(t(), String.t(), String.t()) :: {:ok, t()} | {:error, :enoent | :eperm | :eexist}
  def link(%__MODULE__{data: data} = fs, existing_path, new_path) do
    existing_norm = Fs.normalize_path(existing_path)
    new_norm = Fs.normalize_path(new_path)

    cond do
      not Map.has_key?(data, existing_norm) ->
        {:error, :enoent}

      Map.get(data, existing_norm).type != :file ->
        {:error, :eperm}

      Map.has_key?(data, new_norm) ->
        {:error, :eexist}

      true ->
        fs = ensure_parent_dirs(fs, new_norm)
        entry = Map.get(data, existing_norm)
        {:ok, %{fs | data: Map.put(fs.data, new_norm, entry)}}
    end
  end

  @doc """
  Get all paths in the filesystem.
  """
  @spec get_all_paths(t()) :: [String.t()]
  def get_all_paths(%__MODULE__{data: data}) do
    Map.keys(data)
  end

  defp ensure_parent_dirs(%__MODULE__{} = fs, path) do
    dir = Fs.dirname(path)

    if dir == "/" do
      fs
    else
      if Map.has_key?(fs.data, dir) do
        fs
      else
        fs = ensure_parent_dirs(fs, dir)
        entry = %{type: :directory, mode: 0o755, mtime: DateTime.utc_now()}
        %{fs | data: Map.put(fs.data, dir, entry)}
      end
    end
  end

  defp get_entry_following_symlinks(fs, path) do
    do_get_entry_following_symlinks(fs, path, MapSet.new())
  end

  @dialyzer {:nowarn_function, do_get_entry_following_symlinks: 3}
  defp do_get_entry_following_symlinks(%__MODULE__{data: data} = fs, path, seen) do
    case Map.get(data, path) do
      nil ->
        {:error, :enoent}

      %{type: :symlink, target: target} ->
        if MapSet.member?(seen, path) do
          {:error, :eloop}
        else
          resolved = resolve_symlink_target(path, target)
          do_get_entry_following_symlinks(fs, resolved, MapSet.put(seen, path))
        end

      entry ->
        {:ok, entry}
    end
  end

  defp resolve_symlink_target(symlink_path, target) do
    if String.starts_with?(target, "/") do
      Fs.normalize_path(target)
    else
      dir = Fs.dirname(symlink_path)
      combined = if dir == "/", do: "/" <> target, else: dir <> "/" <> target
      Fs.normalize_path(combined)
    end
  end
end
