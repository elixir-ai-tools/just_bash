defmodule JustBash.FS.LazyQueryFSExampleTest do
  @moduledoc """
  Worked example: a read-write backend modeled after a Postgres-backed
  rows table. The "database" here is an `Agent` wrapping a map, and
  every shell op hits a distinct closure — `list_fn` for ls/glob,
  `fetch_fn` for cat, `insert_fn` for redirected writes, `delete_fn`
  for rm.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias JustBash.FS

  defmodule LazyQueryFS do
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

  @row_count 100
  @tag_every 7

  setup do
    {:ok, db} =
      Agent.start_link(fn ->
        for i <- 0..(@row_count - 1), into: %{} do
          val = :erlang.phash2({:row, i}, 1_000_000)
          tag = if rem(i, @tag_every) == 0, do: " banana", else: ""
          {i, "id=#{i} val=#{val}#{tag}\n"}
        end
      end)

    queries = %{
      list_fn: fn -> Agent.get(db, &Map.keys/1) end,
      fetch_fn: fn i ->
        case Agent.get(db, &Map.fetch(&1, i)) do
          {:ok, v} -> {:ok, v}
          :error -> {:error, :enoent}
        end
      end,
      insert_fn: fn i, content ->
        Agent.update(db, &Map.put(&1, i, content))
        :ok
      end,
      delete_fn: fn i ->
        Agent.update(db, &Map.delete(&1, i))
        :ok
      end
    }

    fs = FS.new()
    {:ok, fs} = FS.mount(fs, "/rows", LazyQueryFS.new(queries))
    bash = JustBash.new(fs: fs)

    %{bash: bash, db: db}
  end

  test "ls /rows lists all rows", %{bash: bash} do
    {r, _} = JustBash.exec(bash, "ls /rows | wc -l")
    assert r.exit_code == 0
    assert String.trim(r.stdout) == "#{@row_count}"
  end

  test "cat /rows/row-43 returns that row's content", %{bash: bash, db: db} do
    {r, _} = JustBash.exec(bash, "cat /rows/row-43")
    assert r.exit_code == 0
    assert r.stdout == Agent.get(db, &Map.fetch!(&1, 43))
  end

  test "grep banana /rows/* finds every tagged row", %{bash: bash} do
    {r, _} = JustBash.exec(bash, "grep -l banana /rows/*")
    assert r.exit_code == 0

    matches = r.stdout |> String.split("\n", trim: true) |> Enum.sort()
    expected = for i <- 0..(@row_count - 1), rem(i, @tag_every) == 0, do: "/rows/row-#{i}"
    assert matches == Enum.sort(expected)
  end

  test "echo > /rows/row-200 inserts a new row visible to later queries", ctx do
    %{bash: bash, db: db} = ctx

    {r, bash} = JustBash.exec(bash, "echo 'fresh' > /rows/row-200")
    assert r.exit_code == 0

    assert Agent.get(db, &Map.get(&1, 200)) == "fresh\n"

    {r, _} = JustBash.exec(bash, "cat /rows/row-200")
    assert r.stdout == "fresh\n"

    {r, _} = JustBash.exec(bash, "ls /rows | wc -l")
    assert String.trim(r.stdout) == "#{@row_count + 1}"
  end

  test "rm /rows/row-0 deletes the row", %{bash: bash, db: db} do
    {r, bash} = JustBash.exec(bash, "rm /rows/row-0")
    assert r.exit_code == 0
    refute Agent.get(db, &Map.has_key?(&1, 0))

    {r, _} = JustBash.exec(bash, "ls /rows | wc -l")
    assert String.trim(r.stdout) == "#{@row_count - 1}"
  end

  property "cat /rows/row-<id> returns fetch_fn content for any id", %{bash: bash, db: db} do
    check all i <- integer(0..(@row_count - 1)) do
      {r, _} = JustBash.exec(bash, "cat /rows/row-#{i}")
      assert r.stdout == Agent.get(db, &Map.fetch!(&1, i))
    end
  end
end
