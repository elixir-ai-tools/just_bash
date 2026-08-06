defmodule JustBash.SpecTest.Runner do
  @moduledoc """
  Runs Oils spec tests against JustBash and reports results.
  """

  alias JustBash.SpecTest.Parser
  alias JustBash.SpecTest.Parser.TestCase

  defmodule Result do
    @moduledoc "Result of running a spec test"
    defstruct [
      :test_case,
      :passed,
      :actual_stdout,
      :actual_stderr,
      :actual_status,
      :error,
      skipped: false
    ]

    @type t :: %__MODULE__{
            test_case: TestCase.t(),
            passed: boolean(),
            actual_stdout: String.t() | nil,
            actual_stderr: String.t() | nil,
            actual_status: non_neg_integer() | nil,
            error: String.t() | nil,
            skipped: boolean()
          }
  end

  @doc """
  Run all test cases from a spec file.
  """
  @spec run_file(String.t(), keyword()) :: [Result.t()]
  def run_file(path, opts \\ []) do
    case Parser.parse_file(path) do
      {:ok, test_cases} ->
        run_test_cases(test_cases, opts)

      {:error, reason} ->
        [%Result{test_case: nil, passed: false, error: reason}]
    end
  end

  @doc """
  Run a list of test cases.
  """
  @spec run_test_cases([TestCase.t()], keyword()) :: [Result.t()]
  def run_test_cases(test_cases, opts \\ []) do
    Enum.map(test_cases, &run_test_case(&1, opts))
  end

  @doc """
  Run a single test case.
  """
  @spec run_test_case(TestCase.t(), keyword()) :: Result.t()
  def run_test_case(%TestCase{skip_reason: reason} = tc, _opts) when not is_nil(reason) do
    %Result{test_case: tc, passed: false, skipped: true, error: "Skipped: #{reason}"}
  end

  def run_test_case(%TestCase{} = tc, opts) do
    bash = Keyword.get(opts, :bash, JustBash.new())

    try do
      {result, _bash} = JustBash.exec(bash, tc.script)

      matches? =
        check_output(tc.expected_stdout, result.stdout) and
          check_output(tc.expected_stderr, result.stderr) and
          result.exit_code == tc.expected_status

      %Result{
        test_case: tc,
        passed: matches?,
        actual_stdout: result.stdout,
        actual_stderr: result.stderr,
        actual_status: result.exit_code,
        error: nil
      }
    rescue
      e ->
        %Result{
          test_case: tc,
          passed: false,
          actual_stdout: nil,
          actual_status: nil,
          error: Exception.message(e)
        }
    end
  end

  # A case that asserts nothing about a stream passes on that stream.
  defp check_output(nil, _actual), do: true
  defp check_output(expected, actual), do: expected == actual

  @doc """
  Generate a summary of test results.
  """
  @spec summary([Result.t()]) :: map()
  def summary(results) do
    # A skipped case is neither a pass nor a failure, and does not count
    # against the rate — the corpus carries 247 of them.
    {skipped, ran} = Enum.split_with(results, & &1.skipped)
    passed = Enum.count(ran, & &1.passed)
    failed = Enum.count(ran, &(not &1.passed and is_nil(&1.error)))
    errored = Enum.count(ran, &(not is_nil(&1.error)))
    total = length(ran)

    %{
      total: total,
      passed: passed,
      failed: failed,
      errored: errored,
      skipped: length(skipped),
      pass_rate: if(total > 0, do: Float.round(passed / total * 100, 1), else: 0.0)
    }
  end

  @doc """
  Print a summary of test results.
  """
  @spec print_summary([Result.t()]) :: :ok
  def print_summary(results) do
    s = summary(results)

    IO.puts("\n=== Spec Test Summary ===")
    IO.puts("Total:   #{s.total}")
    IO.puts("Passed:  #{s.passed}")
    IO.puts("Failed:  #{s.failed}")
    IO.puts("Errors:  #{s.errored}")
    IO.puts("Skipped: #{s.skipped}")
    IO.puts("Rate:    #{s.pass_rate}%")

    # Show first few failures
    failures =
      results
      |> Enum.filter(&(not &1.passed and not &1.skipped))
      |> Enum.take(10)

    if failures != [] do
      IO.puts("\n=== First #{length(failures)} Failures ===")

      for result <- failures do
        IO.puts("\n--- #{result.test_case.name} (line #{result.test_case.line_number}) ---")
        IO.puts("Script: #{String.slice(result.test_case.script, 0, 100)}...")

        if result.error do
          IO.puts("Error: #{result.error}")
        else
          IO.puts("Expected stdout: #{inspect(result.test_case.expected_stdout)}")
          IO.puts("Actual stdout:   #{inspect(result.actual_stdout)}")
          IO.puts("Expected stderr: #{inspect(result.test_case.expected_stderr)}")
          IO.puts("Actual stderr:   #{inspect(result.actual_stderr)}")
          IO.puts("Expected status: #{result.test_case.expected_status}")
          IO.puts("Actual status:   #{result.actual_status}")
        end
      end
    end

    :ok
  end
end
