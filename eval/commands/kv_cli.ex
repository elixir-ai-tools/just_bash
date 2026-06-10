defmodule JustBash.Eval.Commands.KVCli do
  @moduledoc """
  The key-value store from `JustBash.Eval.Commands.KV`, ported to `JustBash.CLI`.

  This is the "after" half of the before/after showcase for the CLI feature. Compare with
  `JustBash.Eval.Commands.KV`, which hand-rolls a `case` router, manual `--help`/`-h`/`[]`
  handling, a help string duplicated between `@moduledoc` and a private function, and
  ad-hoc error formatting.

  Here, routing, argument parsing, `--help` at every level, "did you mean" suggestions,
  and the usage lines on errors are all generated from the declarative spec below. The
  handlers only contain storage logic.

  Storage: persisted as JSON at `/.kv_store.json`, identical to the original.
  """

  use JustBash.CLI

  alias JustBash.CLI
  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @store_path "/.kv_store.json"

  @impl JustBash.CLI
  def spec do
    CLI.new("kv",
      doc: "A key-value store backed by a JSON file in the virtual filesystem",
      commands: [
        CLI.command("set",
          doc: "Store a key-value pair",
          args: [
            %{name: :key, required: true, doc: "Key to store under"},
            %{name: :value, required: true, variadic: true, doc: "Value (may contain spaces)"}
          ],
          run: &set/1
        ),
        CLI.command("get",
          doc: "Retrieve a value (exit 1 if not found)",
          args: [%{name: :key, required: true, doc: "Key to retrieve"}],
          run: &get/1
        ),
        CLI.command("delete",
          doc: "Remove a key (exit 1 if not found)",
          args: [%{name: :key, required: true, doc: "Key to remove"}],
          run: &delete/1
        ),
        CLI.command("list", doc: "List all keys, one per line, sorted", run: &list/1),
        CLI.command("dump", doc: "Dump all key=value pairs, sorted by key", run: &dump/1),
        CLI.command("count", doc: "Print the number of stored keys", run: &count/1)
      ]
    )
  end

  defp set(inv) do
    [key | value_parts] = inv.args
    store = inv.bash.fs |> store_from() |> Map.put(key, Enum.join(value_parts, " "))
    {Command.ok(""), write_store(inv.bash, store)}
  end

  defp get(inv) do
    [key] = inv.args

    case Map.fetch(store_from(inv.bash.fs), key) do
      {:ok, value} -> {Command.ok("#{value}\n"), inv.bash}
      :error -> {Command.error("kv: key '#{key}' not found\n", 1), inv.bash}
    end
  end

  defp delete(inv) do
    [key] = inv.args
    store = store_from(inv.bash.fs)

    if Map.has_key?(store, key) do
      {Command.ok(""), write_store(inv.bash, Map.delete(store, key))}
    else
      {Command.error("kv: key '#{key}' not found\n", 1), inv.bash}
    end
  end

  defp list(inv) do
    keys = inv.bash.fs |> store_from() |> Map.keys() |> Enum.sort()
    {Command.ok(join_lines(keys)), inv.bash}
  end

  defp dump(inv) do
    pairs =
      inv.bash.fs
      |> store_from()
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    {Command.ok(join_lines(pairs)), inv.bash}
  end

  defp count(inv) do
    {Command.ok("#{map_size(store_from(inv.bash.fs))}\n"), inv.bash}
  end

  # --- storage (identical to JustBash.Eval.Commands.KV) ---

  defp store_from(fs) do
    with {:ok, content} <- InMemoryFs.read_file(fs, @store_path),
         {:ok, map} when is_map(map) <- Jason.decode(content) do
      map
    else
      _ -> %{}
    end
  end

  defp write_store(bash, store) do
    {:ok, fs} = InMemoryFs.write_file(bash.fs, @store_path, Jason.encode!(store))
    %{bash | fs: fs}
  end

  defp join_lines([]), do: ""
  defp join_lines(lines), do: Enum.join(lines, "\n") <> "\n"
end
