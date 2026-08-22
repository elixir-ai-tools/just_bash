# A mountable backend whose `readdir/2` returns names in a caller-chosen
# order. The in-memory backend uniq-sorts, so the only way to see whether
# `FS.readdir/2` re-sorts an unrelated directory is a backend that does not.
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
  def stat(b, path), do: {:error, Error.new(:enoent, path: path)}

  def readdir(b, "/"), do: {:ok, b.entries, b}
  def readdir(b, path), do: {:error, Error.new(:enoent, path: path)}

  def capabilities(_), do: MapSet.new([:read])
end
