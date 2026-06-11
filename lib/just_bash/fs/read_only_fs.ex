defmodule JustBash.Fs.ReadOnlyFs do
  @moduledoc """
  A decorator backend that wraps another backend and rejects all mutating
  operations with `{:error, :erofs}`.

  Reads pass through to the inner backend unchanged. Useful for exposing
  immutable snapshots to an agent.

  ## Usage

      inner_state = InMemoryFs.new(%{"/readme.txt" => "hello"})
      ro_state = ReadOnlyFs.new(inner: {InMemoryFs, inner_state})
      {:ok, fs} = Fs.mount(fs, "/snapshot", ReadOnlyFs, ro_state)
  """

  @behaviour JustBash.Fs.Backend

  @type t :: %__MODULE__{inner_mod: module(), inner_state: term()}

  defstruct [:inner_mod, :inner_state]

  @doc """
  Create a new read-only filesystem wrapping an inner backend.

  ## Options

    * `inner:` — `{module, state}` tuple of the backend to wrap (required)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    {mod, state} = Keyword.fetch!(opts, :inner)
    %__MODULE__{inner_mod: mod, inner_state: state}
  end

  # --- Read-through ops ---

  @impl true
  def exists?(%__MODULE__{inner_mod: mod, inner_state: state}, path),
    do: mod.exists?(state, path)

  @impl true
  def stat(%__MODULE__{inner_mod: mod, inner_state: state}, path),
    do: mod.stat(state, path)

  @impl true
  def lstat(%__MODULE__{inner_mod: mod, inner_state: state}, path),
    do: mod.lstat(state, path)

  @impl true
  def read_file(%__MODULE__{inner_mod: mod, inner_state: state}, path),
    do: mod.read_file(state, path)

  @impl true
  def readdir(%__MODULE__{inner_mod: mod, inner_state: state}, path),
    do: mod.readdir(state, path)

  @impl true
  def readlink(%__MODULE__{inner_mod: mod, inner_state: state}, path),
    do: mod.readlink(state, path)

  # --- Mutating ops — all refused ---

  @impl true
  def write_file(%__MODULE__{}, _path, _content, _opts), do: {:error, :erofs}

  @impl true
  def append_file(%__MODULE__{}, _path, _content), do: {:error, :erofs}

  @impl true
  def mkdir(%__MODULE__{}, _path, _opts), do: {:error, :erofs}

  @impl true
  def rm(%__MODULE__{}, _path, _opts), do: {:error, :erofs}

  @impl true
  def chmod(%__MODULE__{}, _path, _mode), do: {:error, :erofs}

  @impl true
  def symlink(%__MODULE__{}, _target, _link_path), do: {:error, :erofs}

  @impl true
  def link(%__MODULE__{}, _existing, _new), do: {:error, :erofs}
end
