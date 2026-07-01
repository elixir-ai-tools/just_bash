defmodule Mix.Tasks.JustBash.Audit do
  @shortdoc "Scan for 0.3-era JustBash filesystem call shapes"

  @moduledoc """
  Scans Elixir source for filesystem call shapes that the 0.3 → 0.4
  migration broke in ways the compiler cannot catch (see `UPGRADING.md`).
  The legacy patterns still compile and then misbehave at runtime:

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

      mix just_bash.audit             # scans lib/
      mix just_bash.audit lib test    # scans multiple paths
      mix just_bash.audit path/to/file.ex

  Prints one line per finding (`file:line [rule] message`) and exits
  non-zero when anything is found, so it can gate CI.

  This task exists for the 0.3 → 0.4 migration window and will be removed
  once the legacy shapes are gone.
  """

  use Mix.Task

  alias Mix.Tasks.JustBash.Audit.Scanner

  @impl Mix.Task
  def run(args) do
    paths = if args == [], do: ["lib"], else: args
    findings = scan_paths(paths)

    Enum.each(findings, fn %{file: file, line: line, rule: rule, message: message} ->
      Mix.shell().info("#{file}:#{line} [#{rule}] #{message}")
    end)

    case findings do
      [] ->
        Mix.shell().info("just_bash.audit: no 0.3-era filesystem usage found")

      _ ->
        Mix.raise(
          "just_bash.audit: #{length(findings)} finding(s) — see UPGRADING.md for the 0.4 shapes"
        )
    end
  end

  @doc false
  # Exposed for the test suite; directories expand to `**/*.{ex,exs}`.
  @spec scan_paths([String.t()]) :: [Scanner.finding()]
  def scan_paths(paths) do
    paths
    |> Enum.flat_map(&expand_path/1)
    |> Enum.uniq()
    |> Enum.flat_map(&Scanner.scan_source(File.read!(&1), &1))
    |> Enum.sort_by(&{&1.file, &1.line})
  end

  defp expand_path(path) do
    cond do
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
      File.regular?(path) -> [path]
      true -> []
    end
  end
end
