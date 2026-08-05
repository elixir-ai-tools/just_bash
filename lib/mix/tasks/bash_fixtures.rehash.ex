defmodule Mix.Tasks.BashFixtures.Rehash do
  @moduledoc """
  Rewrites stored `content_hash` values to match the current case inputs.

  Only needed when a case's stored hash has drifted from its script — either
  because the script was edited without re-recording, or because the hash predates
  the canonicalization in `JustBash.Fixtures`.

  Rehashing deliberately does **not** touch the recorded expectations. It makes
  the drift visible instead of papering over it: after rehashing, the affected
  cases have no recording, `mix bash_fixtures.verify` says so, and re-recording
  produces a diff showing what those cases should have been asserting all along.

      mix bash_fixtures.rehash wc      # adopt current scripts
      mix bash_fixtures wc             # re-derive expectations from real bash
      git diff test/fixtures           # read what changed, and why

  ## Usage

      mix bash_fixtures.rehash              # whole corpus
      mix bash_fixtures.rehash wc cp        # specific suites
      mix bash_fixtures.rehash --dry-run    # report drift, write nothing
  """

  use Mix.Task

  alias JustBash.Fixtures
  alias Mix.Tasks.BashFixtures

  @shortdoc "Recompute stored fixture hashes after a script edit"

  @impl Mix.Task
  def run(args) do
    {opts, suites, _} = OptionParser.parse(args, switches: [dry_run: :boolean])
    dry_run? = Keyword.get(opts, :dry_run, false)

    suites
    |> BashFixtures.discover_case_files()
    |> Enum.sum_by(&rehash_suite(&1, dry_run?))
    |> report(dry_run?)
  end

  # Decoded as ordered objects so rewriting a hash preserves the file's authored
  # key order. Re-encoding from a plain map would reorder every key in the suite,
  # burying a handful of real changes in hundreds of lines of churn.
  defp rehash_suite(case_file, dry_run) do
    suite = Path.basename(case_file, ".json")
    data = case_file |> File.read!() |> Jason.decode!(objects: :ordered_objects)
    cases = fetch(data, "cases")

    {rehashed, drifted} =
      Enum.map_reduce(cases, [], fn test_case, drifted ->
        computed = test_case |> inputs() |> Fixtures.hash_case()

        case fetch(test_case, "content_hash") do
          ^computed ->
            {test_case, drifted}

          stored ->
            {put(test_case, "content_hash", computed),
             [{fetch(test_case, "name"), stored, computed} | drifted]}
        end
      end)

    drifted
    |> Enum.reverse()
    |> Enum.each(fn {name, stored, computed} ->
      Mix.shell().info("  #{suite}: #{stored || "(none)"} -> #{computed}  #{name}")
    end)

    if drifted != [] and not dry_run do
      BashFixtures.write_json!(case_file, put(data, "cases", rehashed))
    end

    length(drifted)
  end

  defp fetch(%Jason.OrderedObject{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  # Replaces in place when present so position is kept, appends otherwise.
  defp put(%Jason.OrderedObject{values: values} = object, key, value) do
    values =
      if List.keymember?(values, key, 0) do
        List.keyreplace(values, key, 0, {key, value})
      else
        values ++ [{key, value}]
      end

    %{object | values: values}
  end

  # JustBash.Fixtures works on plain maps; only the two hashed fields are needed.
  defp inputs(test_case) do
    %{"script" => fetch(test_case, "script"), "files" => fetch(test_case, "files")}
  end

  defp report(0, _dry_run) do
    Mix.shell().info("bash_fixtures.rehash: every stored hash already matches its inputs")
  end

  defp report(count, true) do
    Mix.shell().info("\n#{count} case(s) would be rehashed. Re-run without --dry-run to apply.")
  end

  defp report(count, _dry_run) do
    Mix.shell().info("""

    Rehashed #{count} case(s). Their expectations are now unclaimed, by design.

    Next:
        mix bash_fixtures <suite>   # re-derive expectations from real bash
        git diff test/fixtures      # the diff is the bug report
    """)
  end
end
