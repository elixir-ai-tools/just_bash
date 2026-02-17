defmodule JustBash.SpecTestTest do
  @moduledoc """
  Runs Oils spec tests against JustBash.

  These tests are ported from the Oils project (https://github.com/oils-for-unix/oils)
  which provides a comprehensive bash compatibility test suite.

  Run specific spec file:
    mix test test/spec_tests/spec_test.exs --only spec_file:arith

  Run all spec tests:
    mix test test/spec_tests/spec_test.exs
  """
  use ExUnit.Case, async: true

  alias JustBash.SpecTest.Parser
  alias JustBash.SpecTest.Parser.TestCase

  # Path to spec test files (copied from vercel_just_bash)
  @spec_dir Path.expand("../../vercel_just_bash/src/spec-tests/cases", __DIR__)

  # Spec files we want to run (start with well-supported ones)
  @enabled_spec_files [
    "arith.test.sh",
    "assign.test.sh",
    "var-op-test.test.sh",
    "var-op-strip.test.sh",
    "loop.test.sh"
  ]

  # Known test names to skip (features we don't support yet)
  skip_tests = [
    # Array side effects in indexing - complex feature
    "Side Effect in Array Indexing",
    # Constant with quotes - edge case
    "Constant with quotes like '1'",
    # Strict arith mode
    "Invalid string to int with strict_arith",
    # printenv.py is a test helper we don't have
    "Env value doesn't persist",
    "Env value with equals",
    "Env binding can use preceding bindings, but not subsequent ones",
    "Env value with two quotes",
    "Env value with escaped <",
    "FOO=foo echo [foo]",
    "FOO=foo fun",
    "Multiple temporary envs on the stack"
  ]

  describe "Oils spec tests" do
    for spec_file <- @enabled_spec_files do
      spec_path = Path.join(@spec_dir, spec_file)

      if File.exists?(spec_path) do
        {:ok, test_cases} = Parser.parse_file(spec_path)

        for %TestCase{} = tc <- test_cases do
          # Skip tests in the skip list
          unless tc.name in skip_tests do
            test_name = "#{spec_file}:#{tc.line_number}: #{tc.name}"

            @tag spec_file: Path.basename(spec_file, ".test.sh")
            @tag spec_line: tc.line_number
            test test_name do
              tc = unquote(Macro.escape(tc))
              bash = JustBash.new()

              {result, _} = JustBash.exec(bash, tc.script)

              if tc.expected_stdout != nil do
                assert result.stdout == tc.expected_stdout,
                       """
                       Stdout mismatch for "#{tc.name}"

                       Script:
                       #{tc.script}

                       Expected:
                       #{inspect(tc.expected_stdout)}

                       Actual:
                       #{inspect(result.stdout)}
                       """
              end

              assert result.exit_code == tc.expected_status,
                     """
                     Status mismatch for "#{tc.name}"

                     Script:
                     #{tc.script}

                     Expected status: #{tc.expected_status}
                     Actual status: #{result.exit_code}
                     Stderr: #{result.stderr}
                     """
            end
          end
        end
      end
    end
  end
end
