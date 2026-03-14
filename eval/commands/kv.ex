defmodule JustBash.Eval.Commands.KV do
  @moduledoc """
  A key-value store command backed by a JSON file in the virtual filesystem.

  Usage:
    kv set <key> <value>    Store a key-value pair
    kv get <key>            Retrieve a value (exit 1 if not found)
    kv delete <key>         Remove a key (exit 1 if not found)
    kv list                 List all keys, one per line, sorted
    kv dump                 Dump all key=value pairs, sorted by key
    kv count                Print number of stored keys
    kv --help               Show this help message

  Storage: persisted as JSON at `/.kv_store.json`.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @store_path "/.kv_store.json"

  @impl true
  def names, do: ["kv"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      ["--help"] -> help(bash)
      ["-h"] -> help(bash)
      [] -> help(bash)
      ["set", key | value_parts] -> set(bash, key, Enum.join(value_parts, " "))
      ["get", key] -> get(bash, key)
      ["delete", key] -> delete(bash, key)
      ["list"] -> list(bash)
      ["dump"] -> dump(bash)
      ["count"] -> count(bash)
      [subcmd | _] -> {Command.error("kv: unknown subcommand '#{subcmd}'\n", 1), bash}
    end
  end

  defp help(bash) do
    text = """
    kv - a key-value store

    Usage:
      kv set <key> <value>    Store a key-value pair
      kv get <key>            Retrieve a value (exit 1 if not found)
      kv delete <key>         Remove a key (exit 1 if not found)
      kv list                 List all keys, one per line, sorted
      kv dump                 Dump all key=value pairs, sorted by key
      kv count                Print number of stored keys
      kv --help               Show this help message

    Storage: JSON-backed at #{@store_path}
    """

    {Command.ok(text), bash}
  end

  defp set(bash, key, value) do
    store = read_store(bash.fs)
    store = Map.put(store, key, value)
    bash = write_store(bash, store)
    {Command.ok(""), bash}
  end

  defp get(bash, key) do
    store = read_store(bash.fs)

    case Map.fetch(store, key) do
      {:ok, value} -> {Command.ok("#{value}\n"), bash}
      :error -> {Command.error("kv: key '#{key}' not found\n", 1), bash}
    end
  end

  defp delete(bash, key) do
    store = read_store(bash.fs)

    if Map.has_key?(store, key) do
      store = Map.delete(store, key)
      bash = write_store(bash, store)
      {Command.ok(""), bash}
    else
      {Command.error("kv: key '#{key}' not found\n", 1), bash}
    end
  end

  defp list(bash) do
    store = read_store(bash.fs)

    output =
      store
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join("\n")

    output = if output == "", do: "", else: output <> "\n"
    {Command.ok(output), bash}
  end

  defp dump(bash) do
    store = read_store(bash.fs)

    output =
      store
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

    output = if output == "", do: "", else: output <> "\n"
    {Command.ok(output), bash}
  end

  defp count(bash) do
    store = read_store(bash.fs)
    {Command.ok("#{map_size(store)}\n"), bash}
  end

  defp read_store(fs) do
    case InMemoryFs.read_file(fs, @store_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp write_store(bash, store) do
    content = Jason.encode!(store)
    {:ok, fs} = InMemoryFs.write_file(bash.fs, @store_path, content)
    %{bash | fs: fs}
  end
end
