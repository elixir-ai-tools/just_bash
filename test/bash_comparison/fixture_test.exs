defmodule JustBash.FixtureTest do
  @moduledoc """
  Dynamically loads bash comparison test fixtures from JSON files.

  Test cases are defined in `test/fixtures/bash_cases/*.json`.
  Expected outputs are in `test/fixtures/bash_expected/*.json`.

  Run `mix bash_fixtures` to regenerate expected outputs via Docker.
  """

  use ExUnit.Case, async: true

  @cases_dir Path.expand("../fixtures/bash_cases", __DIR__)
  @expected_dir Path.expand("../fixtures/bash_expected", __DIR__)

  @case_files Path.wildcard(Path.join(@cases_dir, "*.json")) |> Enum.sort()

  for case_file <- @case_files do
    suite = Path.basename(case_file, ".json")
    expected_file = Path.join(@expected_dir, "#{suite}.json")

    if File.exists?(expected_file) do
      cases = case_file |> File.read!() |> Jason.decode!()
      expected = expected_file |> File.read!() |> Jason.decode!()

      # Build a lookup from content_hash -> expected result.
      # Content hash is a SHA-256 of the canonical {script, files} — immune
      # to test renames, only invalidated when actual inputs change.
      expected_by_hash =
        expected
        |> Map.get("results", [])
        |> Enum.into(%{}, fn r -> {r["content_hash"], r} end)

      describe suite do
        for test_case <- cases["cases"] do
          name = test_case["name"]
          script = test_case["script"]
          files = test_case["files"]
          opts = test_case["opts"] || %{}
          content_hash = test_case["content_hash"]

          expected_result =
            if content_hash do
              expected_by_hash[content_hash]
            else
              raise CompileError,
                description:
                  "Fixture case missing content_hash in #{suite}: #{name}. " <>
                    "Regenerate cases with: mix run scripts/extract_bash_cases.exs"
            end

          @tag suite: suite
          if expected_result do
            expected_stdout = expected_result["stdout"]
            expected_stderr = expected_result["stderr"]
            expected_exit = expected_result["exit_code"]

            has_files = is_map(files) and map_size(files) > 0
            ignore_exit = opts["ignore_exit"] == true
            ignore_stderr = opts["ignore_stderr"] == true

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
