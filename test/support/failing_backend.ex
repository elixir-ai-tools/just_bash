# A mountable backend where every operation fails with one configured error
# kind. The in-memory backend cannot produce :eacces, :erofs or :eio — it has
# no permission model and no device to fail — so this is the only way to reach
# those kinds from a shell command and check the message it renders.
defmodule JustBash.Test.FailingBackend do
  @moduledoc false
  @enforce_keys [:kind]
  defstruct [:kind]

  @type t :: %__MODULE__{kind: atom()}
end

defimpl VFS.Mountable, for: JustBash.Test.FailingBackend do
  use VFS.Skeleton

  alias VFS.Error

  def exists?(b, _path), do: {false, b}
  def stat(b, path), do: {:error, Error.new(b.kind, path: path)}
  def readdir(b, path), do: {:error, Error.new(b.kind, path: path)}
  def stream_read(b, path, _opts), do: {:error, Error.new(b.kind, path: path)}
  def write_file(b, path, _content, _opts), do: {:error, Error.new(b.kind, path: path)}
  def mkdir(b, path, _opts), do: {:error, Error.new(b.kind, path: path)}
  def rm(b, path, _opts), do: {:error, Error.new(b.kind, path: path)}

  def capabilities(_), do: MapSet.new([:read, :write])
end
