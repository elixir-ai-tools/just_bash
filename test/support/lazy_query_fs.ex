defmodule JustBash.FS.LazyQueryFS do
  @moduledoc false
  # JIT backend: every shell op issues a distinct query against caller-supplied
  # closures. Models an Ecto/Postgres-backed table of rows where list/fetch/
  # insert/delete are separate statements.

  @behaviour JustBash.FS.Backend

  defstruct [:list_fn, :fetch_fn, :insert_fn, :delete_fn]

  @type t :: %__MODULE__{
          list_fn: (-> [integer()]),
          fetch_fn: (integer() -> {:ok, binary()} | {:error, term()}),
          insert_fn: (integer(), binary() -> :ok | {:error, term()}),
          delete_fn: (integer() -> :ok | {:error, term()})
        }

  @spec new(Enumerable.t()) :: t()
  def new(fns), do: struct!(__MODULE__, fns)

  @dir_stat %{
    is_file: false,
    is_directory: true,
    is_symbolic_link: false,
    mode: 0o755,
    size: 0,
    mtime: ~U[2024-01-01 00:00:00Z]
  }

  @file_stat %{
    is_file: true,
    is_directory: false,
    is_symbolic_link: false,
    mode: 0o644,
    size: 0,
    mtime: ~U[2024-01-01 00:00:00Z]
  }

  @impl true
  def exists?(_state, "/"), do: true
  def exists?(_state, "/row-" <> _), do: true
  def exists?(_state, _), do: false

  @impl true
  def stat(_state, "/"), do: {:ok, @dir_stat}
  def stat(_state, "/row-" <> _), do: {:ok, @file_stat}
  def stat(_state, _), do: {:error, :enoent}

  @impl true
  def lstat(state, path), do: stat(state, path)

  @impl true
  def readdir(%__MODULE__{list_fn: f}, "/"), do: {:ok, Enum.map(f.(), &"row-#{&1}")}
  def readdir(_state, _path), do: {:error, :enotdir}

  @impl true
  def read_file(state, "/row-" <> idx) do
    with {i, ""} <- Integer.parse(idx) do
      state.fetch_fn.(i)
    else
      _ -> {:error, :enoent}
    end
  end

  def read_file(_state, _path), do: {:error, :enoent}

  @impl true
  def write_file(state, "/row-" <> idx, content, _opts) do
    with {i, ""} <- Integer.parse(idx),
         :ok <- state.insert_fn.(i, content) do
      {:ok, state}
    else
      _ -> {:error, :einval}
    end
  end

  def write_file(_state, _path, _content, _opts), do: {:error, :einval}

  @impl true
  def rm(state, "/row-" <> idx, _opts) do
    with {i, ""} <- Integer.parse(idx),
         :ok <- state.delete_fn.(i) do
      {:ok, state}
    else
      _ -> {:error, :enoent}
    end
  end

  def rm(_state, _path, _opts), do: {:error, :erofs}

  @impl true
  def append_file(_state, _path, _content), do: {:error, :einval}
  @impl true
  def mkdir(_state, _path, _opts), do: {:error, :erofs}
  @impl true
  def chmod(_state, _path, _mode), do: {:error, :erofs}
  @impl true
  def symlink(_state, _target, _link), do: {:error, :erofs}
  @impl true
  def readlink(_state, _path), do: {:error, :einval}
  @impl true
  def link(_state, _existing, _new), do: {:error, :erofs}
end
