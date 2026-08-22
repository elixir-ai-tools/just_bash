# A mountable backend whose `readdir/2` returns names in a caller-chosen
# order, as a Stream. VFS uniq-sorts bounded *list* listings itself, so a
# list would hide whether `FS.readdir/2` / `Special.merge_children/2`
# re-sorts an unrelated directory.
defmodule JustBash.Test.OrderedReaddirBackend do
  @moduledoc false
  defstruct entries: []
end

defimpl VFS.Mountable, for: JustBash.Test.OrderedReaddirBackend do
  use VFS.Skeleton

  alias VFS.{Error, Stat}

  @mtime ~U[1970-01-01 00:00:00Z]

  def exists?(b, "/"), do: {true, b}
  def exists?(b, _path), do: {false, b}

  def stat(b, "/"), do: {:ok, Stat.directory(@mtime), b}
  def stat(_b, path), do: {:error, Error.new(:enoent, path: path)}

  def readdir(b, "/"), do: {:ok, Stream.map(b.entries, &Function.identity/1), b}
  def readdir(_b, path), do: {:error, Error.new(:enoent, path: path)}

  def stream_read(_b, path, _opts), do: {:error, Error.new(:enoent, path: path)}
  def write_file(_b, path, _content, _opts), do: {:error, Error.new(:erofs, path: path)}
  def mkdir(_b, path, _opts), do: {:error, Error.new(:erofs, path: path)}
  def rm(_b, path, _opts), do: {:error, Error.new(:erofs, path: path)}

  def capabilities(_), do: MapSet.new([:read])
end
