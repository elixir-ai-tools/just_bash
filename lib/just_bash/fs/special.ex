defmodule JustBash.FS.Special do
  @moduledoc """
  Device nodes the filesystem layer services itself, rather than storing
  them in a backend.

  `/dev/null` is the one device the shell already handled on the write
  side of redirection (`> /dev/null` discards). It did not exist in the
  VFS, so `cat /dev/null` and `test -e /dev/null` failed even while
  `cat < /dev/null` succeeded. Resolution consults this table so the
  read side, the write side, and the operand side agree.

  `/dev` is the directory that holds it. Without that node, `tee /dev/null`
  would fail looking up the parent, and `ls /dev` would report the path
  missing. Other `/dev` nodes (`zero`, `stdin`, `stdout`, `stderr`) are
  not in the table; add them here if the same invariant ever needs them.
  """

  alias VFS.Error
  alias VFS.Stat

  @type kind :: :null | :directory

  @null "/dev/null"
  @dev "/dev"
  @mtime ~U[1970-01-01 00:00:00Z]

  @doc """
  Look up a *normalized* path in the special-file table.

  Callers must pass a path that `JustBash.FS.normalize_path/1` has already
  rooted and collapsed, so `/dev/./null` and `/dev/null` name the same node.
  """
  @spec lookup(String.t()) :: {:ok, kind()} | :none
  def lookup(@null), do: {:ok, :null}
  def lookup(@dev), do: {:ok, :directory}
  def lookup(_path), do: :none

  @doc "True when a normalized path is the null device."
  @spec null?(String.t()) :: boolean()
  def null?(path), do: lookup(path) == {:ok, :null}

  @doc """
  Virtual children a special path (or `/`) contributes to `readdir`.

  `/` lists `dev` so the directory that holds `/dev/null` is visible;
  `/dev` lists `null`.
  """
  @spec children(String.t()) :: [String.t()]
  def children("/"), do: ["dev"]
  def children(@dev), do: ["null"]
  def children(_path), do: []

  @spec merge_children(String.t(), [String.t()]) :: [String.t()]
  def merge_children(path, entries) do
    entries
    |> Enum.concat(children(path))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec read_file(term(), kind(), String.t()) :: {:ok, binary(), term()} | {:error, Error.t()}
  def read_file(fs, :null, _path), do: {:ok, "", fs}
  def read_file(_fs, :directory, path), do: {:error, Error.new(:eisdir, path: path)}

  @spec write_file(term(), kind(), String.t(), binary()) :: {:ok, term()} | {:error, Error.t()}
  def write_file(fs, :null, _path, _content), do: {:ok, fs}
  def write_file(_fs, :directory, path, _content), do: {:error, Error.new(:eisdir, path: path)}

  @spec append_file(term(), kind(), String.t(), binary()) :: {:ok, term()} | {:error, Error.t()}
  def append_file(fs, :null, _path, _content), do: {:ok, fs}
  def append_file(_fs, :directory, path, _content), do: {:error, Error.new(:eisdir, path: path)}

  @spec exists?(term(), kind()) :: {true, term()}
  def exists?(fs, _kind), do: {true, fs}

  @spec stat(term(), kind(), String.t()) :: {:ok, Stat.t(), term()}
  def stat(fs, :null, _path) do
    {:ok, %Stat{type: :regular, size: 0, mode: 0o666, mtime: @mtime}, fs}
  end

  def stat(fs, :directory, _path) do
    {:ok, %Stat{type: :directory, size: 0, mode: 0o755, mtime: @mtime}, fs}
  end

  @spec stream_read(term(), kind(), String.t(), keyword()) ::
          {:ok, Enumerable.t(), term()} | {:error, Error.t()}
  def stream_read(fs, :null, path, opts) do
    case VFS.StreamOptions.apply("", opts) do
      {:ok, stream} -> {:ok, stream, fs}
      {:error, kind} -> {:error, Error.new(kind, path: path)}
    end
  end

  def stream_read(_fs, :directory, path, _opts), do: {:error, Error.new(:eisdir, path: path)}

  @spec readdir(term(), kind(), String.t(), [String.t()]) ::
          {:ok, [String.t()], term()} | {:error, Error.t()}
  def readdir(_fs, :null, path, _backend_entries), do: {:error, Error.new(:enotdir, path: path)}

  def readdir(fs, :directory, path, backend_entries) do
    {:ok, merge_children(path, backend_entries), fs}
  end

  @spec rm(kind(), String.t()) :: {:error, Error.t()}
  def rm(_kind, path), do: {:error, Error.new(:eacces, path: path)}

  @spec mkdir(term(), kind(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def mkdir(fs, :directory, path, opts) do
    if Keyword.get(opts, :parents, false) do
      {:ok, fs}
    else
      {:error, Error.new(:eexist, path: path)}
    end
  end

  def mkdir(_fs, :null, path, _opts), do: {:error, Error.new(:eexist, path: path)}

  @spec chmod(term(), kind()) :: {:ok, term()}
  def chmod(fs, _kind), do: {:ok, fs}

  @spec readlink(kind(), String.t()) :: {:error, Error.t()}
  def readlink(_kind, path), do: {:error, Error.new(:einval, path: path)}

  @spec refuse_create(String.t()) :: {:error, Error.t()}
  def refuse_create(path), do: {:error, Error.new(:eexist, path: path)}

  @spec refuse_link(kind(), String.t()) :: {:error, Error.t()}
  def refuse_link(_kind, path), do: {:error, Error.new(:eacces, path: path)}
end
