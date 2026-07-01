defmodule JustBash.MigrationAudit do
  @moduledoc """
  Static scanner for host-side code that still uses 0.3-era filesystem
  call shapes.

  The 0.3 → 0.4 filesystem migration (see `UPGRADING.md`) changed several
  return shapes in ways the compiler cannot catch — the legacy patterns
  still compile and then misbehave at runtime:

  | Rule | Legacy shape | Failure mode in 0.4 |
  |---|---|---|
  | `legacy_module` | `JustBash.Fs` / `InMemoryFs` reference | compile error (undefined module) |
  | `stale_ok_tuple` | `{:ok, x}` matched on a read | silently falls through to the error clause |
  | `atom_error` | `{:error, :enoent}` clause | never matches; falls to catch-all or crashes |
  | `exists_truthy` | `FS.exists?/2` in a condition | tuple is always truthy — branch always taken |
  | `legacy_opt` | `mkdir recursive:` / `rm force:` | raises `ArgumentError` at runtime |
  | `stat_boolean_field` | `stat.is_file` etc. | `KeyError` at runtime |
  | `fs_data_access` | `bash.fs.data` | `KeyError` — `bash.fs` is a `%VFS{}` |

  Calls are recognized on the `JustBash.FS` module, a discovered
  `alias JustBash.FS[, as: ...]`, or the bare `FS` name (heuristic).
  Run it over a codebase with `mix just_bash.audit [paths]`.
  """

  @type finding :: %{file: String.t(), line: non_neg_integer(), rule: atom(), message: String.t()}

  # Reads whose success shape grew from {:ok, payload} to {:ok, payload, fs}.
  @three_tuple_reads [:read_file, :readlink, :stat, :lstat, :readdir]

  @stat_boolean_fields [:is_file, :is_directory, :is_symbolic_link]

  @doc """
  Scan Elixir source text. `file` is used only for reporting — this module
  never touches the real filesystem (the sandbox rule); `mix just_bash.audit`
  does the file reading.

  Unparseable source produces a single `:parse_error` finding.
  """
  @spec scan_source(String.t(), String.t()) :: [finding()]
  def scan_source(source, file) do
    case Code.string_to_quoted(source, columns: false) do
      {:ok, ast} ->
        fs_names = fs_alias_names(ast)

        {_, findings} =
          Macro.prewalk(ast, [], fn node, acc ->
            {node, check_node(node, fs_names, file) ++ acc}
          end)

        Enum.sort_by(findings, & &1.line)

      {:error, {meta, message, token}} ->
        line = Keyword.get(meta, :line, 0)

        [
          finding(
            file,
            line,
            :parse_error,
            "could not parse: #{inspect(message)} #{inspect(token)}"
          )
        ]
    end
  end

  # ── alias discovery ────────────────────────────────────────────────────

  # Local names that refer to JustBash.FS: the bare `FS` heuristic plus any
  # `alias JustBash.FS`, `alias JustBash.FS, as: X`, or `alias JustBash.{FS, ...}`.
  defp fs_alias_names(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new([:FS]), fn
        {:alias, _, [{:__aliases__, _, [:JustBash, :FS]}]} = node, acc ->
          {node, MapSet.put(acc, :FS)}

        {:alias, _, [{:__aliases__, _, [:JustBash, :FS]}, opts]} = node, acc ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [name]} -> {node, MapSet.put(acc, name)}
            _ -> {node, acc}
          end

        {:alias, _, [{{:., _, [{:__aliases__, _, [:JustBash]}, :{}]}, _, group}]} = node, acc ->
          if Enum.any?(group, &match?({:__aliases__, _, [:FS]}, &1)) do
            {node, MapSet.put(acc, :FS)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    names
  end

  # ── per-node rules ─────────────────────────────────────────────────────

  defp check_node({:__aliases__, meta, [:JustBash, :Fs | _]} = node, _fs_names, file) do
    [
      finding(
        file,
        line(meta),
        :legacy_module,
        "references removed module #{Macro.to_string(node)} — use JustBash.FS (see UPGRADING.md)"
      )
    ]
  end

  defp check_node({:__aliases__, meta, [:InMemoryFs]}, _fs_names, file) do
    [
      finding(
        file,
        line(meta),
        :legacy_module,
        "references removed module InMemoryFs — use JustBash.FS (see UPGRADING.md)"
      )
    ]
  end

  # {pattern} = FS.fun(...)
  defp check_node({:=, _, [pattern, rhs]}, fs_names, file) do
    check_result_pattern(pattern, rhs, fs_names, file)
  end

  # case FS.fun(...) do pattern -> ... end
  defp check_node({:case, _, [scrutinee, [do: clauses]]}, fs_names, file) do
    clauses
    |> List.wrap()
    |> Enum.flat_map(fn
      {:->, _, [[pattern], _body]} -> check_result_pattern(pattern, scrutinee, fs_names, file)
      _ -> []
    end)
  end

  # with {pattern} <- FS.fun(...)
  defp check_node({:<-, _, [pattern, rhs]}, fs_names, file) do
    check_result_pattern(pattern, rhs, fs_names, file)
  end

  # FS.exists? in condition position
  defp check_node({op, _, [condition | _]}, fs_names, file)
       when op in [:if, :unless, :!, :not, :assert, :refute] do
    exists_truthy_finding(condition, fs_names, file)
  end

  defp check_node({op, _, [left, right]}, fs_names, file) when op in [:&&, :||, :and, :or] do
    exists_truthy_finding(left, fs_names, file) ++ exists_truthy_finding(right, fs_names, file)
  end

  # stat.is_file / bash.fs.data — dot access chains
  defp check_node({{:., meta, [base, field]}, _, []}, _fs_names, file)
       when field in @stat_boolean_fields or field == :data do
    cond do
      field in @stat_boolean_fields ->
        [
          finding(
            file,
            line(meta),
            :stat_boolean_field,
            ".#{field} is not a VFS.Stat field — match on stat.type " <>
              "(:regular | :directory | :symlink) instead"
          )
        ]

      match?({{:., _, [_, :fs]}, _, []}, base) ->
        [
          finding(
            file,
            line(meta),
            :fs_data_access,
            ".fs.data reaches into 0.3 struct internals — bash.fs is a %VFS{} mount table; " <>
              "use JustBash.FS functions"
          )
        ]

      true ->
        []
    end
  end

  # %{is_file: ...} map literal or pattern
  defp check_node({:%{}, meta, kvs}, _fs_names, file) when is_list(kvs) do
    keys = for {k, _} <- kvs, is_atom(k), do: k

    if Enum.any?(keys, &(&1 in @stat_boolean_fields)) do
      [
        finding(
          file,
          line(meta),
          :stat_boolean_field,
          "map with #{inspect(Enum.filter(keys, &(&1 in @stat_boolean_fields)))} looks like a " <>
            "0.3 stat map — stats are %VFS.Stat{type: ...} structs now"
        )
      ]
    else
      []
    end
  end

  defp check_node(node, fs_names, file) do
    check_legacy_opts(node, fs_names, file)
  end

  # ── result-shape checks ────────────────────────────────────────────────

  defp check_result_pattern(pattern, rhs, fs_names, file) do
    case fs_call(rhs, fs_names) do
      nil -> []
      {fun, meta} -> pattern_findings(strip_when(pattern), fun, meta, file)
    end
  end

  defp pattern_findings({:ok, _payload}, fun, meta, file)
       when fun in @three_tuple_reads do
    [
      finding(
        file,
        line(meta),
        :stale_ok_tuple,
        "matches {:ok, _} on FS.#{fun} — success is now {:ok, payload, fs}; " <>
          "this clause silently never matches"
      )
    ]
  end

  defp pattern_findings({:error, kind}, fun, meta, file) when is_atom(kind) do
    [
      finding(
        file,
        line(meta),
        :atom_error,
        "matches {:error, #{inspect(kind)}} on FS.#{fun} — errors are now " <>
          "%VFS.Error{kind: #{inspect(kind)}} structs; this clause silently never matches"
      )
    ]
  end

  defp pattern_findings(pat, :exists?, meta, file) when pat in [true, false] do
    [
      finding(
        file,
        line(meta),
        :exists_truthy,
        "matches a bare boolean on FS.exists? — it returns {boolean, fs} now"
      )
    ]
  end

  defp pattern_findings(_pattern, _fun, _meta, _file), do: []

  defp strip_when({:when, _, [pattern | _]}), do: pattern
  defp strip_when(pattern), do: pattern

  defp exists_truthy_finding(node, fs_names, file) do
    case fs_call(node, fs_names) do
      {:exists?, meta} ->
        [
          finding(
            file,
            line(meta),
            :exists_truthy,
            "FS.exists?/2 returns {boolean, fs} — a tuple is always truthy here; " <>
              "destructure it first"
          )
        ]

      _ ->
        []
    end
  end

  # ── legacy options ─────────────────────────────────────────────────────

  defp check_legacy_opts(node, fs_names, file) do
    case fs_call(node, fs_names) do
      {:mkdir, meta} ->
        legacy_opt_finding(node, :recursive, "mkdir", "parents: true", meta, file)

      {:rm, meta} ->
        legacy_opt_finding(node, :force, "rm", "handling :enoent yourself", meta, file)

      _ ->
        []
    end
  end

  defp legacy_opt_finding(node, key, fun, replacement, meta, file) do
    opts =
      case node do
        {_, _, args} when is_list(args) -> List.last(args)
        _ -> nil
      end

    if Keyword.keyword?(opts) and Keyword.has_key?(opts, key) do
      [
        finding(
          file,
          line(meta),
          :legacy_opt,
          "FS.#{fun} has no #{inspect(key)} option in 0.4 — use #{replacement} " <>
            "(raises ArgumentError at runtime)"
        )
      ]
    else
      []
    end
  end

  # ── call recognition ───────────────────────────────────────────────────

  # Returns {fun, meta} when node is a call on JustBash.FS (or an alias of
  # it), unwrapping one level of |>. Otherwise nil.
  defp fs_call({:|>, _, [_, call]}, fs_names), do: fs_call(call, fs_names)

  defp fs_call({{:., _, [{:__aliases__, meta, mods}, fun]}, _, args}, fs_names)
       when is_atom(fun) and is_list(args) do
    if fs_module?(mods, fs_names), do: {fun, meta}
  end

  defp fs_call(_, _), do: nil

  defp fs_module?([:JustBash, :FS], _fs_names), do: true
  defp fs_module?([name], fs_names), do: MapSet.member?(fs_names, name)
  defp fs_module?(_, _), do: false

  # ── helpers ────────────────────────────────────────────────────────────

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_), do: 0

  defp finding(file, line, rule, message) do
    %{file: file, line: line, rule: rule, message: message}
  end
end
