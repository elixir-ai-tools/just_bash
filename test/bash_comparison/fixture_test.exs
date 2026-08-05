defmodule JustBash.FixtureTest do
  @moduledoc """
  Asserts JustBash matches real bash, byte for byte, on the recorded corpus.

  Cases live in `test/fixtures/bash_cases/*.json`; what real bash produced for
  them lives in `test/fixtures/bash_expected/*.json`. Recording needs Docker
  (`mix bash_fixtures`), but this test compares against the recording, so it
  runs offline.

  The two files are joined by `content_hash`, a digest of the case inputs. The
  hash is **recomputed** here rather than read from the case file: a stored hash
  that is never re-derived is just an opaque label, and a case whose script was
  edited without re-recording would keep passing while asserting against output
  recorded for a different script. Recomputing makes that a compile error.

  See `mix bash_fixtures.verify` for the same checks as a friendly offline
  report, and `mix bash_fixtures.rehash` to adopt edited scripts.

  A case carrying `opts.known_gap` is one JustBash is known not to match yet. It
  still runs, tagged `:known_gap`, with the assertion inverted: it fails when the
  output *matches* the recording. A gap that is skipped instead can only report
  the divergence someone wrote down and can never notice the divergence is gone,
  so a gap closed by an unrelated fix would stay marked forever — and a count of
  known gaps that includes closed ones is not a count of anything.
  """

  use ExUnit.Case, async: true

  alias JustBash.Fixtures

  @cases_dir Path.expand("../fixtures/bash_cases", __DIR__)
  @expected_dir Path.expand("../fixtures/bash_expected", __DIR__)

  @case_files Path.wildcard(Path.join(@cases_dir, "*.json")) |> Enum.sort()

  for case_file <- @case_files do
    suite = Path.basename(case_file, ".json")
    expected_file = Path.join(@expected_dir, "#{suite}.json")

    if File.exists?(expected_file) do
      cases = case_file |> File.read!() |> Jason.decode!()
      expected = expected_file |> File.read!() |> Jason.decode!()
      results = Map.get(expected, "results", [])

      # A broken join makes every assertion in the suite untrustworthy, so the
      # two problems that corrupt it fail the build. A merely missing recording
      # is reported per-case below, and orphans are left to bash_fixtures.verify.
      fatal =
        cases["cases"]
        |> Fixtures.validate(results)
        |> Enum.filter(&(elem(&1, 0) in [:stale_hash, :hash_collision]))

      if fatal != [] do
        raise CompileError,
          description:
            "Fixture corpus integrity failure in #{suite}:\n" <>
              Enum.map_join(fatal, "\n", &"  - #{Fixtures.describe(&1)}") <>
              "\n\nRun `mix bash_fixtures.verify` for the full report."
      end

      expected_by_hash = Map.new(results, fn r -> {r["content_hash"], r} end)

      describe suite do
        for test_case <- cases["cases"] do
          name = test_case["name"]
          script = test_case["script"]
          files = test_case["files"]
          opts = test_case["opts"] || %{}
          content_hash = Fixtures.hash_case(test_case)
          expected_result = expected_by_hash[content_hash]

          known_gap = opts["known_gap"]

          @tag suite: suite
          if known_gap, do: @tag(:known_gap)

          if expected_result do
            expected_stdout = expected_result["stdout"]
            expected_stderr = expected_result["stderr"]
            expected_exit = expected_result["exit_code"]

            has_files = is_map(files) and map_size(files) > 0
            ignore_exit = opts["ignore_exit"] == true
            ignore_stderr = opts["ignore_stderr"] == true

            # A recorded case JustBash is known not to match yet. The expectation
            # stays recorded and the reason stays in the corpus, so the gap is
            # visible and countable rather than absent — an unwritten case looks
            # exactly like a passing one.
            #
            # The assertion is inverted rather than skipped. A skipped gap can
            # only ever report the divergence someone wrote down; it cannot
            # notice that the divergence is gone, so a gap closed by an unrelated
            # fix stays marked forever and the count stops meaning anything.
            if known_gap do
              test "#{suite}: #{name}" do
                {result, _bash} =
                  JustBash.exec(
                    JustBash.new(files: unquote(Macro.escape(files || %{}))),
                    unquote(script)
                  )

                actual = {result.exit_code, result.stdout, result.stderr}

                recorded =
                  {unquote(expected_exit), unquote(expected_stdout), unquote(expected_stderr)}

                refute actual == recorded, """
                Known gap has closed: #{unquote(name)}

                  #{unquote(known_gap)}

                JustBash now matches real bash here. Drop the `known_gap` opt from
                the case so the match is asserted rather than assumed absent.
                """
              end
            else
              test "#{suite}: #{name}" do
                bash =
                  if unquote(has_files) do
                    JustBash.new(files: unquote(Macro.escape(files)))
                  else
                    JustBash.new()
                  end

                {result, _bash} = JustBash.exec(bash, unquote(script))

                unless unquote(ignore_exit) do
                  assert result.exit_code == unquote(expected_exit),
                         fixture_failure_message(
                           unquote(script),
                           "exit_code",
                           unquote(expected_exit),
                           result.exit_code
                         )
                end

                assert result.stdout == unquote(expected_stdout),
                       fixture_failure_message(
                         unquote(script),
                         "stdout",
                         unquote(expected_stdout),
                         result.stdout
                       )

                unless unquote(ignore_stderr) do
                  assert result.stderr == unquote(expected_stderr),
                         fixture_failure_message(
                           unquote(script),
                           "stderr",
                           unquote(expected_stderr),
                           result.stderr
                         )
                end
              end
            end
          else
            test "#{suite}: #{name}" do
              flunk(
                "No expected result for content_hash #{unquote(content_hash)}. " <>
                  "Run: mix bash_fixtures #{unquote(suite)}"
              )
            end
          end
        end
      end
    end
  end

  defp fixture_failure_message(script, field, expected, actual) do
    """
    Fixture mismatch for: #{String.slice(script, 0, 200)}
    Field: #{field}
    Expected: #{inspect(expected)}
    Actual:   #{inspect(actual)}
    """
  end
end
