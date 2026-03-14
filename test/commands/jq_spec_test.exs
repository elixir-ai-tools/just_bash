defmodule JustBash.Commands.JqSpecTest.Parser do
  @moduledoc false

  @doc """
  Parses the jq test file format into a list of test cases.

  Returns a list of `{program, input, expected_output_lines, line_number}` tuples.
  """
  def parse(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> do_parse([], [])
    |> Enum.reverse()
  end

  @doc """
  Parses the jq test file and extracts %%FAIL test cases.

  Returns a list of `{program, line_number}` tuples for programs expected to fail.
  """
  def parse_fail_cases(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> do_parse_fail([])
    |> Enum.reverse()
  end

  defp do_parse_fail([], cases), do: cases

  defp do_parse_fail([{line, line_num} | rest], cases) do
    trimmed = String.trim(line)

    if trimmed == "%%FAIL" or trimmed == "%%FAIL IGNORE MSG" do
      # Next non-empty line is the program
      case rest do
        [{program, _} | tail] ->
          remaining = skip_until_blank(tail)
          do_parse_fail(remaining, [{String.trim(program), line_num} | cases])

        [] ->
          cases
      end
    else
      do_parse_fail(rest, cases)
    end
  end

  defp skip_until_blank([]), do: []

  defp skip_until_blank([{line, _} | rest]) do
    if String.trim(line) == "", do: rest, else: skip_until_blank(rest)
  end

  defp do_parse([], group, cases), do: flush(group, cases)

  defp do_parse([{line, line_num} | rest], group, cases) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        do_parse(rest, [], flush(group, cases))

      trimmed == "%%FAIL" or trimmed == "%%FAIL IGNORE MSG" ->
        do_parse(skip_fail_block(rest), [], flush(group, cases))

      String.starts_with?(trimmed, "#") ->
        do_parse(rest, group, cases)

      true ->
        do_parse(rest, group ++ [{trimmed, line_num}], cases)
    end
  end

  defp skip_fail_block([]), do: []

  defp skip_fail_block([{line, _} | rest]) do
    if String.trim(line) == "", do: rest, else: skip_fail_block(rest)
  end

  defp flush([], cases), do: cases
  defp flush(group, cases) when length(group) < 3, do: cases

  defp flush([{program, line_num}, {input, _} | expected_lines], cases) do
    expected = Enum.map(expected_lines, fn {line, _} -> line end)
    [{program, input, expected, line_num} | cases]
  end
end

defmodule JustBash.Commands.JqSpecTest do
  @moduledoc """
  Runs the upstream jq test suite (jq.test) against our jq implementation.

  Calls the jq Parser and Evaluator directly to avoid shell escaping issues.
  Output is formatted in jq's "compact with spaces" format (JV_PRINT_SPACE1)
  to match the spec file's expected output format.
  """

  use ExUnit.Case, async: true

  alias JustBash.Commands.Jq.{Evaluator, Parser}

  @moduletag :jq_spec

  @spec_file Path.expand("../command_spec_cases/jq/cases/jq.test", __DIR__)

  @spec_content File.read!(@spec_file)

  @spec_cases @spec_content |> JustBash.Commands.JqSpecTest.Parser.parse()
  @fail_cases @spec_content |> JustBash.Commands.JqSpecTest.Parser.parse_fail_cases()

  for {program, input, expected, line_num} <- @spec_cases do
    expected_output = Enum.join(expected, "\n")

    test_name =
      if String.length(program) > 80 do
        String.slice(program, 0, 77) <> "..."
      else
        program
      end

    test "L#{line_num}: #{test_name}" do
      program = unquote(program)
      input_str = unquote(input)
      expected_output = unquote(expected_output)

      # Parse the jq filter
      case Parser.parse(program) do
        {:error, reason} ->
          flunk("""
          jq spec: parse error at line #{unquote(line_num)}
          Program:  #{program}
          Error:    #{inspect(reason)}
          Expected: #{inspect(expected_output)}
          """)

        {:ok, ast} ->
          # Parse the input JSON
          input_data =
            case parse_jq_json(input_str) do
              {:ok, data} -> data
              {:error, _} -> :parse_error
            end

          if input_data == :parse_error do
            flunk("""
            jq spec: input parse error at line #{unquote(line_num)}
            Program:  #{program}
            Input:    #{input_str}
            Expected: #{inspect(expected_output)}
            """)
          else
            # Evaluate
            modules_dir = Path.expand("../command_spec_cases/jq/modules", __DIR__)
            eval_opts = %{module_paths: [modules_dir]}

            case Evaluator.evaluate(ast, input_data, eval_opts) do
              {:ok, results} ->
                expected_values = parse_expected(expected_output)

                assert results == expected_values,
                       """
                       jq spec mismatch at line #{unquote(line_num)}
                       Program:  #{program}
                       Input:    #{input_str}
                       Expected: #{inspect(expected_values)}
                       Actual:   #{inspect(results)}
                       """

              {:error, msg} ->
                flunk("""
                jq spec: evaluation error at line #{unquote(line_num)}
                Program:  #{program}
                Input:    #{input_str}
                Error:    #{inspect(msg)}
                Expected: #{inspect(expected_output)}
                """)
            end
          end
      end
    end
  end

  # %%FAIL tests: programs expected to fail at parse or evaluation time
  for {program, line_num} <- @fail_cases do
    test_name =
      if String.length(program) > 80 do
        String.slice(program, 0, 77) <> "..."
      else
        program
      end

    test "FAIL L#{line_num}: #{test_name}" do
      program = unquote(program)

      case Parser.parse(program) do
        {:error, _reason} ->
          # Parse error — expected
          :ok

        {:ok, ast} ->
          # Parsed OK, but evaluation should fail
          modules_dir = Path.expand("../command_spec_cases/jq/modules", __DIR__)
          eval_opts = %{module_paths: [modules_dir]}

          case Evaluator.evaluate(ast, nil, eval_opts) do
            {:error, _msg} ->
              :ok

            {:ok, results} ->
              flunk("""
              jq spec FAIL test at line #{unquote(line_num)} unexpectedly succeeded
              Program:  #{program}
              Results:  #{inspect(results)}
              Expected: parse or evaluation error
              """)
          end
      end
    end
  end

  # Parse JSON input, handling jq-specific extensions:
  # - BOM (byte order mark) prefix
  # - Infinity, -Infinity, NaN, -NaN, nan literals
  defp parse_jq_json(str) do
    # Strip BOM
    str = String.replace_prefix(str, "\uFEFF", "")

    # Replace jq-specific number literals with JSON-compatible values
    # Use a sentinel string for NaN so we can restore :nan atoms after parsing
    str =
      str
      |> String.replace(~r/(?<!["\w])-Infinity(?!["\w])/, "-1.7976931348623157e+308")
      |> String.replace(~r/(?<!["\w])Infinity(?!["\w])/, "1.7976931348623157e+308")
      |> String.replace(~r/(?<!["\w])-NaN(?!["\w])/, "\"__NAN_SENTINEL__\"")
      |> String.replace(~r/(?<!["\w])NaN(?!["\w])/, "\"__NAN_SENTINEL__\"")
      |> String.replace(~r/(?<!["\w])nan(?!["\w])/, "\"__NAN_SENTINEL__\"")

    case Jason.decode(str) do
      {:ok, data} -> {:ok, data |> restore_nan_sentinels() |> clamp_large_ints()}
      error -> error
    end
  end

  defp restore_nan_sentinels("__NAN_SENTINEL__"), do: :nan

  defp restore_nan_sentinels(list) when is_list(list),
    do: Enum.map(list, &restore_nan_sentinels/1)

  defp restore_nan_sentinels(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, restore_nan_sentinels(v)} end)

  defp restore_nan_sentinels(other), do: other

  # jq (without have_decnum) stores numbers as IEEE 754 doubles.
  # Integers larger than 2^53 lose precision. Simulate this by
  # converting large ints to floats then back to ints.
  @max_safe_int trunc(:math.pow(2, 53))
  defp clamp_large_ints(n) when is_integer(n) and (n > @max_safe_int or n < -@max_safe_int) do
    # Convert to float and back to simulate precision loss
    trunc(n / 1.0)
  end

  defp clamp_large_ints(list) when is_list(list) do
    Enum.map(list, &clamp_large_ints/1)
  end

  defp clamp_large_ints(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, clamp_large_ints(v)} end)
  end

  defp clamp_large_ints(other), do: other

  # Parse each expected output line as JSON to get Elixir values.
  defp parse_expected(str) do
    str
    |> String.split("\n")
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, val} -> val |> restore_nan_sentinels() |> clamp_large_ints()
        {:error, _} -> parse_raw_expected(line)
      end
    end)
  end

  # Try to parse raw expected values that Jason can't handle (extreme numbers, etc.)
  defp parse_raw_expected(line) do
    # Try to match extreme scientific notation like 9E+999999999
    case Regex.run(~r/^([+-]?\d+(?:\.\d+)?)[eE]([+-]?\d+)$/, line) do
      [_, _mantissa, exp_str] ->
        {exp, ""} = Integer.parse(exp_str)

        cond do
          exp > 300 -> 1.7_976_931_348_623_157e308
          exp < -300 -> 0.0
          true -> {:raw, line}
        end

      nil ->
        {:raw, line}
    end
  end
end
