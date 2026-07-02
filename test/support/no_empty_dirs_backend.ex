# A backend where files are writable but empty directories cannot exist —
# the shape of any git-tree-backed mount (e.g. an exgit workspace). With
# `read_only: true`, mutations fail with :erofs instead.
defmodule JustBash.Test.NoEmptyDirsBackend do
  @moduledoc false
  defstruct files: %{}, read_only: false
end

defimpl VFS.Mountable, for: JustBash.Test.NoEmptyDirsBackend do
  use VFS.Skeleton

  alias VFS.{Error, Stat}

  @mtime ~U[1970-01-01 00:00:00Z]

  def exists?(b, path), do: {path == "/" or Map.has_key?(b.files, path), b}

  def stat(b, "/"), do: {:ok, Stat.directory(@mtime), b}

  def stat(b, path) do
    case Map.fetch(b.files, path) do
      {:ok, content} -> {:ok, Stat.regular(byte_size(content), @mtime), b}
      :error -> {:error, Error.new(:enoent, path: path)}
    end
  end

  def readdir(b, "/"),
    do: {:ok, b.files |> Map.keys() |> Enum.map(&String.trim_leading(&1, "/")), b}

  def readdir(_b, path), do: {:error, Error.new(:enoent, path: path)}

  def stream_read(b, path, opts) do
    with {:ok, content} <- Map.fetch(b.files, path),
         {:ok, stream} <- VFS.StreamOptions.apply(content, opts) do
      {:ok, stream, b}
    else
      :error -> {:error, Error.new(:enoent, path: path)}
      {:error, kind} -> {:error, Error.new(kind, path: path)}
    end
  end

  def write_file(%{read_only: true}, path, _content, _opts),
    do: {:error, Error.new(:erofs, path: path)}

  def write_file(b, path, content, _opts),
    do: {:ok, %{b | files: Map.put(b.files, path, content)}}

  def mkdir(_b, path, _opts) do
    {:error, Error.new(:enotsup, path: path, message: "backend cannot store empty directories")}
  end

  def rm(%{read_only: true}, path, _opts), do: {:error, Error.new(:erofs, path: path)}
  def rm(b, path, _opts), do: {:ok, %{b | files: Map.delete(b.files, path)}}

  def capabilities(_), do: MapSet.new([:read, :write])
end
