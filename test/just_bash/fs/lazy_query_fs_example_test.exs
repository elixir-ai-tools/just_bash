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
  alias JustBash.FS.LazyQueryFS

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
