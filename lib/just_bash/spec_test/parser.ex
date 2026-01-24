defmodule JustBash.SpecTest.Parser do
  @moduledoc """
  Parser for Oils spec test format (.test.sh files).

  The format is:
  - Lines starting with `##` are metadata (compare_shells, oils_failures_allowed)
  - Lines starting with `####` are test case names
  - Following lines until the next `##` directive are the script
  - `## stdout:` single line expected stdout
  - `## STDOUT:` ... `## END` multiline expected stdout
  - `## status:` expected exit status (default 0)
  - `## N-I` (not implemented) and `## BUG` mark shell-specific behaviors

  Example:
      #### Add one to var
      i=1
      echo $(($i+1))
      ## stdout: 2
  """

  defmodule TestCase do
    @moduledoc "Represents a single spec test case"
    defstruct [
      :name,
      :script,
      :expected_stdout,
      :expected_status,
      :skip_reason,
      :line_number
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            script: String.t(),
            expected_stdout: String.t() | nil,
            expected_status: non_neg_integer(),
            skip_reason: String.t() | nil,
            line_number: pos_integer()
          }
  end

  @doc """
  Parse a spec test file and return a list of test cases.
  """
  @spec parse_file(String.t()) :: {:ok, [TestCase.t()]} | {:error, String.t()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse(content)}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Parse spec test content and return a list of test cases.
  """
  @spec parse(String.t()) :: [TestCase.t()]
  def parse(content) do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> extract_test_cases([])
    |> Enum.reverse()
  end

  defp extract_test_cases([], acc), do: acc

  defp extract_test_cases([{line, line_num} | rest], acc) do
    if String.starts_with?(line, "#### ") do
      name = String.trim_leading(line, "#### ")
      {test_case, remaining} = parse_test_case(name, line_num, rest)
      extract_test_cases(remaining, [test_case | acc])
    else
      extract_test_cases(rest, acc)
    end
  end

  defp parse_test_case(name, line_num, lines) do
    {script_lines, rest} = collect_script(lines, [])
    {expectations, remaining} = collect_expectations(rest, %{stdout: nil, status: 0, skip: nil})

    script = script_lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    test_case = %TestCase{
      name: name,
      script: script,
      expected_stdout: expectations.stdout,
      expected_status: expectations.status,
      skip_reason: expectations.skip,
      line_number: line_num
    }

    {test_case, remaining}
  end

  defp collect_script([], acc), do: {acc, []}

  defp collect_script([{line, _} | rest] = lines, acc) do
    cond do
      String.starts_with?(line, "#### ") ->
        {acc, lines}

      String.starts_with?(line, "## ") ->
        {acc, lines}

      true ->
        collect_script(rest, [line | acc])
    end
  end

  defp collect_expectations([], acc), do: {acc, []}

  defp collect_expectations([{line, _} | rest] = lines, acc) do
    cond do
      String.starts_with?(line, "#### ") ->
        {acc, lines}

      String.starts_with?(line, "## stdout: ") ->
        stdout = String.trim_leading(line, "## stdout: ")
        collect_expectations(rest, %{acc | stdout: stdout <> "\n"})

      String.starts_with?(line, "## stdout-json: ") ->
        json = String.trim_leading(line, "## stdout-json: ")
        stdout = parse_json_string(json)
        collect_expectations(rest, %{acc | stdout: stdout})

      String.starts_with?(line, "## STDOUT:") ->
        {stdout, remaining} = collect_multiline_stdout(rest, [])
        collect_expectations(remaining, %{acc | stdout: stdout})

      String.starts_with?(line, "## status: ") ->
        status = line |> String.trim_leading("## status: ") |> String.to_integer()
        collect_expectations(rest, %{acc | status: status})

      String.starts_with?(line, "## N-I ") ->
        # Not implemented in some shells - we might skip or handle differently
        collect_expectations(rest, acc)

      String.starts_with?(line, "## BUG ") ->
        # Bug in some shells - skip this expectation
        collect_expectations(rest, acc)

      String.starts_with?(line, "## OK ") ->
        # OK for some shells - skip
        collect_expectations(rest, acc)

      String.starts_with?(line, "## ") ->
        # Other directives we don't handle yet
        collect_expectations(rest, acc)

      true ->
        # Comment or blank line, continue
        collect_expectations(rest, acc)
    end
  end

  defp collect_multiline_stdout([], acc) do
    {acc |> Enum.reverse() |> Enum.join("\n"), []}
  end

  defp collect_multiline_stdout([{line, _} | rest], acc) do
    cond do
      line == "## END" ->
        stdout = acc |> Enum.reverse() |> Enum.join("\n")
        # Add trailing newline if content exists
        stdout = if stdout != "", do: stdout <> "\n", else: stdout
        {stdout, rest}

      String.starts_with?(line, "## ") ->
        # Another directive, end multiline
        stdout = acc |> Enum.reverse() |> Enum.join("\n")
        stdout = if stdout != "", do: stdout <> "\n", else: stdout
        {stdout, [{line, 0} | rest]}

      true ->
        collect_multiline_stdout(rest, [line | acc])
    end
  end

  defp parse_json_string(json) do
    # Handle simple JSON string escapes
    json
    |> String.trim("\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end
end
