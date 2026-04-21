defmodule JustBash.FS.NullFS do
  @moduledoc false
  # A /dev/null-style backend for testing mount-table mechanics.
  # Returns :enoent for every query and {:ok, :unit} for every mutation.

  @behaviour JustBash.FS.Backend

  @type t :: %__MODULE__{}

  defstruct []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def exists?(%__MODULE__{}, _path), do: false

  @impl true
  def stat(%__MODULE__{}, _path), do: {:error, :enoent}

  @impl true
  def lstat(%__MODULE__{}, _path), do: {:error, :enoent}

  @impl true
  def read_file(%__MODULE__{}, _path), do: {:error, :enoent}

  @impl true
  def readdir(%__MODULE__{}, _path), do: {:error, :enoent}

  @impl true
  def readlink(%__MODULE__{}, _path), do: {:error, :enoent}

  @impl true
  def write_file(s = %__MODULE__{}, _path, _content, _opts), do: {:ok, s}

  @impl true
  def append_file(s = %__MODULE__{}, _path, _content), do: {:ok, s}

  @impl true
  def mkdir(s = %__MODULE__{}, _path, _opts), do: {:ok, s}

  @impl true
  def rm(s = %__MODULE__{}, _path, _opts), do: {:ok, s}

  @impl true
  def chmod(s = %__MODULE__{}, _path, _mode), do: {:ok, s}

  @impl true
  def symlink(s = %__MODULE__{}, _target, _link), do: {:ok, s}

  @impl true
  def link(s = %__MODULE__{}, _existing, _new), do: {:ok, s}
end
