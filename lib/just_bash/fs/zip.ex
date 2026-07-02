defmodule JustBash.FS.Zip do
  @moduledoc """
  Read-only `VFS.Mountable` backend backed by a ZIP archive.

  ZIP contents are loaded eagerly at construction time into immutable Elixir
  data structures. That keeps shell execution deterministic: once mounted,
  `ls`, `cat`, glob expansion, `cp` out of the mount, and `find` operate without
  further network access. Mutations fail with `:erofs`.

  Use `from_binary/2` when the caller already has archive bytes. Use
  `from_url/3` to fetch through `JustBash`'s network policy and HTTP client.

  ## Examples

      iex> {:ok, {_name, bytes}} = :zip.create(~c"docs.zip", [{~c"README.md", "hello"}], [:memory])
      iex> {:ok, zip} = JustBash.FS.Zip.from_binary(bytes)
      iex> {:ok, content, _zip} = VFS.read_file(zip, "/README.md")
      iex> content
      "hello"
  """

  alias JustBash.Network
  alias VFS.Error
  alias VFS.Path, as: VPath

  @enforce_keys [:files, :dirs, :mtime]
  defstruct [:files, :dirs, :mtime]

  @type files :: %{String.t() => binary()}

  @type t :: %__MODULE__{
          files: files(),
          dirs: MapSet.t(String.t()),
          mtime: DateTime.t()
        }

  @type from_binary_opts :: [
          mtime: DateTime.t(),
          max_archive_bytes: pos_integer(),
          max_uncompressed_bytes: pos_integer(),
          max_entries: pos_integer(),
          max_path_bytes: pos_integer()
        ]

  @type from_url_opts :: [
          timeout: pos_integer(),
          mtime: DateTime.t(),
          max_archive_bytes: pos_integer(),
          max_uncompressed_bytes: pos_integer(),
          max_entries: pos_integer(),
          max_path_bytes: pos_integer()
        ]

  @default_mtime ~U[1970-01-01 00:00:00Z]
  @default_timeout 15_000
  @default_max_archive_bytes 50 * 1024 * 1024
  @default_max_uncompressed_bytes 250 * 1024 * 1024
  @default_max_entries 100_000
  @default_max_path_bytes 4_096

  @doc """
  Build a read-only ZIP filesystem from archive bytes.

  Archive entry paths must be relative POSIX paths. Absolute paths, `.`/`..`
  segments, empty path segments, NUL bytes, backslashes, duplicate entries, and
  file/directory collisions return `{:error, %VFS.Error{kind: :einval}}`.

  Safety limits default to:

    * `:max_archive_bytes` - 50 MiB compressed input
    * `:max_uncompressed_bytes` - 250 MiB total uncompressed entries
    * `:max_entries` - 100,000 entries
    * `:max_path_bytes` - 4,096 bytes per entry path
  """
  @spec from_binary(binary(), from_binary_opts()) :: {:ok, t()} | {:error, Error.t()}
  def from_binary(zip_bytes, opts \\ []) when is_binary(zip_bytes) and is_list(opts) do
    mtime = Keyword.get(opts, :mtime, @default_mtime)

    with :ok <- validate_mtime(mtime),
         :ok <- validate_archive(zip_bytes, opts),
         {:ok, entries} <- unzip(zip_bytes),
         {:ok, files, dirs} <- build_index(entries) do
      {:ok, %__MODULE__{files: files, dirs: dirs, mtime: mtime}}
    end
  end

  @doc """
  Build a read-only ZIP filesystem from archive bytes, raising on failure.
  """
  @spec from_binary!(binary(), from_binary_opts()) :: t()
  def from_binary!(zip_bytes, opts \\ []) do
    case from_binary(zip_bytes, opts) do
      {:ok, zip} -> zip
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Fetch a ZIP archive through `JustBash`'s network policy and build a backend.

  The fetch uses `bash.http_client` when present, otherwise
  `JustBash.HttpClient.Default`. Redirects are followed manually by
  `JustBash.Network`, so each redirect target is checked against the same
  allow-list and HTTPS policy as `curl`/`wget`.
  """
  @spec from_url(JustBash.t(), String.t(), from_url_opts()) :: {:ok, t()} | {:error, Error.t()}
  def from_url(%JustBash{} = bash, url, opts \\ []) when is_binary(url) and is_list(opts) do
    with :ok <- validate_url_access(bash, url),
         {:ok, body} <- fetch_url(bash, url, opts) do
      from_binary(body, opts)
    end
  end

  @doc """
  Fetch a ZIP archive through `JustBash`'s network policy, raising on failure.
  """
  @spec from_url!(JustBash.t(), String.t(), from_url_opts()) :: t()
  def from_url!(%JustBash{} = bash, url, opts \\ []) do
    case from_url(bash, url, opts) do
      {:ok, zip} -> zip
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc false
  @spec __normalize__(String.t()) :: String.t()
  def __normalize__(path), do: normalize(path)

  @doc false
  @spec __file__(t(), String.t()) :: binary() | nil
  def __file__(%__MODULE__{files: files}, path), do: Map.get(files, path)

  @doc false
  @spec __file?(t(), String.t()) :: boolean()
  def __file?(%__MODULE__{files: files}, path), do: Map.has_key?(files, path)

  @doc false
  @spec __dir?(t(), String.t()) :: boolean()
  def __dir?(%__MODULE__{dirs: dirs}, path), do: MapSet.member?(dirs, path)

  @doc false
  @spec __children__(t(), String.t()) :: [String.t()]
  def __children__(%__MODULE__{files: files, dirs: dirs}, dir) do
    prefix = if dir == "/", do: "/", else: dir <> "/"

    file_children = files |> Map.keys() |> direct_children(prefix)

    dir_children =
      dirs
      |> MapSet.delete(dir)
      |> MapSet.to_list()
      |> direct_children(prefix)

    (file_children ++ dir_children)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unzip(zip_bytes) do
    case :zip.unzip(zip_bytes, [:memory]) do
      {:ok, entries} ->
        {:ok, entries}

      {:error, reason} ->
        {:error,
         Error.new(:einval,
           message: "invalid zip archive: #{inspect(reason)}"
         )}
    end
  end

  defp validate_archive(zip_bytes, opts) do
    with {:ok, max_archive_bytes} <-
           positive_integer_opt(opts, :max_archive_bytes, @default_max_archive_bytes),
         {:ok, max_uncompressed_bytes} <-
           positive_integer_opt(opts, :max_uncompressed_bytes, @default_max_uncompressed_bytes),
         {:ok, max_entries} <- positive_integer_opt(opts, :max_entries, @default_max_entries),
         {:ok, max_path_bytes} <-
           positive_integer_opt(opts, :max_path_bytes, @default_max_path_bytes),
         :ok <- validate_archive_size(zip_bytes, max_archive_bytes),
         {:ok, table_entries} <- zip_table(zip_bytes) do
      validate_table_entries(table_entries, max_uncompressed_bytes, max_entries, max_path_bytes)
    end
  end

  defp zip_table(zip_bytes) do
    case :zip.table(zip_bytes) do
      {:ok, table_entries} ->
        {:ok, table_entries}

      {:error, reason} ->
        {:error,
         Error.new(:einval,
           message: "invalid zip archive: #{inspect(reason)}"
         )}
    end
  end

  defp validate_archive_size(zip_bytes, max_archive_bytes) do
    if byte_size(zip_bytes) <= max_archive_bytes do
      :ok
    else
      {:error,
       Error.new(:einval,
         message:
           "zip archive is too large: #{byte_size(zip_bytes)} bytes exceeds #{max_archive_bytes} bytes"
       )}
    end
  end

  defp validate_table_entries(table_entries, max_uncompressed_bytes, max_entries, max_path_bytes) do
    table_entries
    |> Enum.reduce_while({:ok, 0, 0}, fn
      {:zip_file, raw_name, file_info, _comment, _offset, _comp_size}, {:ok, entries, bytes} ->
        with :ok <- validate_path_size(raw_name, max_path_bytes),
             {:ok, _entry} <- normalize_entry_name(raw_name) do
          entries = entries + 1
          bytes = bytes + file_info_size(file_info)

          cond do
            entries > max_entries ->
              {:halt,
               {:error,
                Error.new(:einval,
                  message: "zip archive has too many entries: #{entries} exceeds #{max_entries}"
                )}}

            bytes > max_uncompressed_bytes ->
              {:halt,
               {:error,
                Error.new(:einval,
                  message:
                    "zip archive expands to too many bytes: #{bytes} exceeds #{max_uncompressed_bytes}"
                )}}

            true ->
              {:cont, {:ok, entries, bytes}}
          end
        else
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      _entry, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, _entries, _bytes} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_path_size(raw_name, max_path_bytes) do
    name = to_string(raw_name)

    if byte_size(name) <= max_path_bytes do
      :ok
    else
      {:error,
       Error.new(:einval,
         message:
           "zip entry path is too long: #{byte_size(name)} bytes exceeds #{max_path_bytes} bytes"
       )}
    end
  end

  defp file_info_size(
         {:file_info, size, _type, _access, _atime, _mtime, _ctime, _mode, _links, _major_device,
          _minor_device, _inode, _uid, _gid}
       )
       when is_integer(size) and size >= 0,
       do: size

  defp file_info_size(_file_info), do: 0

  defp build_index(entries) do
    Enum.reduce_while(entries, {:ok, %{}, MapSet.new(["/"])}, fn {raw_name, content},
                                                                 {:ok, files, dirs} ->
      case normalize_entry_name(raw_name) do
        {:ok, {:dir, path}} ->
          add_dir(path, files, dirs)

        {:ok, {:file, path}} when is_binary(content) ->
          add_file(path, content, files, dirs)

        {:ok, {:file, path}} ->
          error =
            Error.new(:einval, path: path, message: "zip entry content is not binary: #{path}")

          {:halt, {:error, error}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp add_dir(path, files, dirs) do
    cond do
      Map.has_key?(files, path) ->
        error = Error.new(:einval, path: path, message: "zip entry collides with file: #{path}")
        {:halt, {:error, error}}

      file_parent = file_parent(path, files) ->
        error = Error.new(:einval, path: path, message: "zip entry is below file: #{file_parent}")
        {:halt, {:error, error}}

      true ->
        {:cont, {:ok, files, MapSet.union(dirs, parent_dirs(path)) |> MapSet.put(path)}}
    end
  end

  defp add_file(path, content, files, dirs) do
    cond do
      Map.has_key?(files, path) ->
        error = Error.new(:einval, path: path, message: "duplicate zip file entry: #{path}")
        {:halt, {:error, error}}

      MapSet.member?(dirs, path) ->
        error =
          Error.new(:einval, path: path, message: "zip entry collides with directory: #{path}")

        {:halt, {:error, error}}

      file_parent = file_parent(path, files) ->
        error = Error.new(:einval, path: path, message: "zip entry is below file: #{file_parent}")
        {:halt, {:error, error}}

      true ->
        {:cont, {:ok, Map.put(files, path, content), MapSet.union(dirs, parent_dirs(path))}}
    end
  end

  defp normalize_entry_name(raw_name) do
    name = to_string(raw_name)
    dir? = String.ends_with?(name, "/")
    trimmed = if dir?, do: binary_part(name, 0, byte_size(name) - 1), else: name

    cond do
      name == "" or trimmed == "" ->
        invalid_entry(name, "empty zip entry path")

      String.contains?(name, <<0>>) ->
        invalid_entry(name, "zip entry path contains NUL byte")

      String.starts_with?(name, "/") ->
        invalid_entry(name, "zip entry path must be relative")

      String.contains?(name, "\\") ->
        invalid_entry(name, "zip entry path must use POSIX / separators")

      true ->
        normalize_entry_segments(name, trimmed, dir?)
    end
  end

  defp normalize_entry_segments(original, trimmed, dir?) do
    parts = String.split(trimmed, "/")

    if Enum.any?(parts, &(&1 in ["", ".", ".."])) do
      invalid_entry(original, "zip entry path contains unsafe segment")
    else
      kind = if dir?, do: :dir, else: :file
      {:ok, {kind, "/" <> Enum.join(parts, "/")}}
    end
  end

  defp invalid_entry(name, reason) do
    {:error, Error.new(:einval, message: "#{reason}: #{inspect(name)}")}
  end

  defp parent_dirs(path) do
    path
    |> VPath.dirname()
    |> do_parent_dirs(MapSet.new(["/"]))
  end

  defp do_parent_dirs("/", acc), do: acc

  defp do_parent_dirs(path, acc) do
    do_parent_dirs(VPath.dirname(path), MapSet.put(acc, path))
  end

  defp file_parent(path, files) do
    path
    |> parent_dirs()
    |> MapSet.delete("/")
    |> Enum.find(&Map.has_key?(files, &1))
  end

  defp direct_children(paths, prefix) do
    paths
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn path ->
      path
      |> String.replace_prefix(prefix, "")
      |> String.split("/", parts: 2)
      |> hd()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp validate_url_access(bash, url) do
    case Network.validate_access(bash, url, "zip mount") do
      :ok -> :ok
      {:error, message} -> {:error, Error.new(:eacces, message: String.trim_trailing(message))}
    end
  end

  defp fetch_url(%JustBash{} = bash, url, opts) do
    with {:ok, timeout} <- positive_integer_opt(opts, :timeout, @default_timeout) do
      client = bash.http_client || JustBash.HttpClient.Default

      request = %{
        method: :get,
        url: url,
        headers: %{},
        body: nil,
        timeout: timeout,
        follow_redirects: false,
        insecure: false
      }

      case Network.follow_redirects(bash, request, "zip mount", &client.request/1) do
        {:response, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
          {:ok, body}

        {:response, %{status: status}} ->
          {:error, Error.new(:eio, message: "zip mount fetch failed with HTTP #{status}")}

        {:error, %{reason: reason}} ->
          {:error, Error.new(:eio, message: "zip mount fetch failed: #{inspect(reason)}")}
      end
    end
  end

  defp validate_mtime(%DateTime{}), do: :ok

  defp validate_mtime(other) do
    {:error,
     Error.new(:einval, message: "expected :mtime to be a DateTime, got: #{inspect(other)}")}
  end

  defp positive_integer_opt(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      invalid_positive_integer_opt(key, value)
    end
  end

  defp invalid_positive_integer_opt(key, value) do
    {:error,
     Error.new(:einval,
       message: "expected #{inspect(key)} to be a positive integer, got: #{inspect(value)}"
     )}
  end

  defp normalize(""), do: "/"
  defp normalize("/" <> _ = path), do: VPath.normalize(path)
  defp normalize(path), do: VPath.normalize("/" <> path)
end

defimpl VFS.Mountable, for: JustBash.FS.Zip do
  use VFS.Skeleton

  alias JustBash.FS.Zip
  alias VFS.Error
  alias VFS.Stat

  def exists?(%Zip{} = zip, path) do
    normalized = Zip.__normalize__(path)
    {Zip.__file?(zip, normalized) or Zip.__dir?(zip, normalized), zip}
  end

  def stat(%Zip{} = zip, path) do
    normalized = Zip.__normalize__(path)

    cond do
      Zip.__file?(zip, normalized) ->
        size = zip |> Zip.__file__(normalized) |> byte_size()
        {:ok, Stat.regular(size, zip.mtime, 0o444), zip}

      Zip.__dir?(zip, normalized) ->
        {:ok, Stat.directory(zip.mtime, 0o555), zip}

      true ->
        {:error, Error.new(:enoent, path: normalized)}
    end
  end

  def readdir(%Zip{} = zip, path) do
    normalized = Zip.__normalize__(path)

    cond do
      Zip.__dir?(zip, normalized) ->
        {:ok, Zip.__children__(zip, normalized), zip}

      Zip.__file?(zip, normalized) ->
        {:error, Error.new(:enotdir, path: normalized)}

      true ->
        {:error, Error.new(:enoent, path: normalized)}
    end
  end

  def stream_read(%Zip{} = zip, path, opts) do
    normalized = Zip.__normalize__(path)

    cond do
      Zip.__file?(zip, normalized) ->
        case VFS.StreamOptions.apply(Zip.__file__(zip, normalized), opts) do
          {:ok, stream} -> {:ok, stream, zip}
          {:error, kind} -> {:error, Error.new(kind, path: normalized)}
        end

      Zip.__dir?(zip, normalized) ->
        {:error, Error.new(:eisdir, path: normalized)}

      true ->
        {:error, Error.new(:enoent, path: normalized)}
    end
  end

  def write_file(_zip, path, _content, _opts) do
    {:error, Error.new(:erofs, path: Zip.__normalize__(path))}
  end

  def mkdir(_zip, path, _opts) do
    {:error, Error.new(:erofs, path: Zip.__normalize__(path))}
  end

  def rm(_zip, path, _opts) do
    {:error, Error.new(:erofs, path: Zip.__normalize__(path))}
  end

  def capabilities(_zip), do: MapSet.new([:read])
end

defimpl JustBash.FS.POSIX, for: JustBash.FS.Zip do
  alias JustBash.FS.Zip
  alias VFS.Error

  def lstat(%Zip{} = zip, path), do: VFS.stat(zip, path)

  def readlink(%Zip{} = zip, path) do
    normalized = Zip.__normalize__(path)

    if Zip.__file?(zip, normalized) or Zip.__dir?(zip, normalized) do
      {:error, Error.new(:einval, path: normalized)}
    else
      {:error, Error.new(:enoent, path: normalized)}
    end
  end

  def symlink(_zip, _target, link_path),
    do: {:error, Error.new(:erofs, path: Zip.__normalize__(link_path))}

  def link(_zip, _existing_path, new_path),
    do: {:error, Error.new(:erofs, path: Zip.__normalize__(new_path))}

  def chmod(_zip, path, _mode), do: {:error, Error.new(:erofs, path: Zip.__normalize__(path))}

  def append_file(_zip, path, _content),
    do: {:error, Error.new(:erofs, path: Zip.__normalize__(path))}
end
