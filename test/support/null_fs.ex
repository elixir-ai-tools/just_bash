defmodule JustBash.FS.NullFS do
  @moduledoc false
  # A /dev/null-style backend for testing mount-table mechanics.
  # Returns :enoent for every query and {:ok, :unit} for every mutation.

  @behaviour JustBash.FS.Backend

  @type t :: :unit

  @spec new() :: t()
  def new, do: :unit

  @impl true
  def exists?(:unit, _path), do: false

  @impl true
  def stat(:unit, _path), do: {:error, :enoent}

  @impl true
  def lstat(:unit, _path), do: {:error, :enoent}

  @impl true
  def read_file(:unit, _path), do: {:error, :enoent}

  @impl true
  def readdir(:unit, _path), do: {:error, :enoent}

  @impl true
  def readlink(:unit, _path), do: {:error, :enoent}

  @impl true
  def write_file(:unit, _path, _content, _opts), do: {:ok, :unit}

  @impl true
  def append_file(:unit, _path, _content), do: {:ok, :unit}

  @impl true
  def mkdir(:unit, _path, _opts), do: {:ok, :unit}

  @impl true
  def rm(:unit, _path, _opts), do: {:ok, :unit}

  @impl true
  def chmod(:unit, _path, _mode), do: {:ok, :unit}

  @impl true
  def symlink(:unit, _target, _link), do: {:ok, :unit}

  @impl true
  def link(:unit, _existing, _new), do: {:ok, :unit}
end
