defmodule Mix.Tasks.BashFixtures.Verify do
  @moduledoc """
  Checks the fixture corpus for integrity. Offline — no Docker.

  Cases in `test/fixtures/bash_cases/` are joined to the bash output recorded in
  `test/fixtures/bash_expected/` by `content_hash`, a digest of the case inputs.
  Because the hash is derived from the script, "someone edited a script but never
  re-recorded it" is detectable without running bash at all — the recomputed hash
  simply has no recording. That is what lets the PR pipeline stay hermetic while
  still refusing to accept a stale corpus.

  Reports, per suite:

    * **stale hash** — the stored hash is not the digest of the current inputs,
      so the case is joined to a recording made from a different script
    * **no recording** — a case whose expectation was never recorded
    * **orphan recording** — a recording no live case claims
    * **hash collision** — one hash claimed by cases with differing inputs

  ## Usage

      mix bash_fixtures.verify              # whole corpus
      mix bash_fixtures.verify wc cp        # specific suites

  Exits non-zero when anything is wrong, so it can gate CI.
  """

  use Mix.Task

  alias JustBash.Fixtures
  alias Mix.Tasks.BashFixtures

  @shortdoc "Check fixture corpus integrity (offline)"

  @impl Mix.Task
  def run(args) do
    {_opts, suites, _} = OptionParser.parse(args, switches: [])

    results =
      suites
      |> BashFixtures.discover_case_files()
      |> Enum.map(&verify_suite/1)

    report(results, Enum.sum_by(results, fn {_suite, problems} -> length(problems) end))
  end

  defp verify_suite(case_file) do
    suite = Path.basename(case_file, ".json")
    expected_file = Path.join(BashFixtures.expected_dir(), "#{suite}.json")

    cases = case_file |> BashFixtures.read_json!() |> Map.fetch!("cases")

    results =
      if File.exists?(expected_file) do
        expected_file |> BashFixtures.read_json!() |> Map.get("results", [])
      else
        []
      end

    {suite, Fixtures.validate(cases, results)}
  end

  defp report(results, 0) do
    Mix.shell().info("bash_fixtures.verify: #{length(results)} suites sound")
  end

  defp report(results, total_problems) do
    for {suite, problems} <- results, problems != [] do
      Mix.shell().error("\n#{suite} (#{length(problems)}):")

      for problem <- problems do
        Mix.shell().error("  - #{Fixtures.describe(problem)}")
      end
    end

    Mix.raise("""

    #{total_problems} fixture integrity problem(s).

    A stale hash means the script was edited after its expectation was recorded,
    so the case is asserting against output for a different script. To adopt the
    current scripts and re-derive their expectations from real bash:

        mix bash_fixtures.rehash <suite>
        mix bash_fixtures <suite>

    Read the resulting diff: it shows what those cases should have been asserting.
    """)
  end
end
