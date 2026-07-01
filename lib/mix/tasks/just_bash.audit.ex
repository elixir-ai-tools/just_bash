defmodule Mix.Tasks.JustBash.Audit do
  @shortdoc "Scan for 0.3-era JustBash filesystem call shapes"

  @moduledoc """
  Scans Elixir source for filesystem call shapes that the 0.3 → 0.4
  migration broke in ways the compiler cannot catch (see `UPGRADING.md`
  and `JustBash.MigrationAudit` for the rule list).

      mix just_bash.audit             # scans lib/
      mix just_bash.audit lib test    # scans multiple paths
      mix just_bash.audit path/to/file.ex

  Prints one line per finding (`file:line [rule] message`) and exits
  non-zero when anything is found, so it can gate CI.
  """

  use Mix.Task

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

  @doc """
  Scan the given files and directories (directories expand to
  `**/*.{ex,exs}`). Returns findings sorted by file and line.

  Lives on the Mix task (host-side tooling) rather than
  `JustBash.MigrationAudit` because it reads the real filesystem;
  the scanner itself is pure.
  """
  @spec scan_paths([String.t()]) :: [JustBash.MigrationAudit.finding()]
  def scan_paths(paths) do
    paths
    |> Enum.flat_map(&expand_path/1)
    |> Enum.uniq()
    |> Enum.flat_map(&JustBash.MigrationAudit.scan_source(File.read!(&1), &1))
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
