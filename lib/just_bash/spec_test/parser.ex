defmodule JustBash.SpecTest.Parser do
  @moduledoc """
  Parser for Oils spec test format (.test.sh files).

  A file is a run of cases. Each case opens with `#### <name>`; every line
  after that up to the next `####` is either a `##` directive or a line of the
  script, in any order — Oils puts `## SKIP` *above* the script and the
  expectations below it.

  Directives:

    * `## stdout: LINE` / `## stderr: LINE` — one expected line
    * `## stdout-json: "…"` / `## stderr-json: "…"` — an escaped expectation,
      the only way to express output with no trailing newline
    * `## STDOUT:` … `## END` / `## STDERR:` … `## END` — multiline
    * `## status: N` — expected exit status (default 0)
    * `## SKIP (why): reason` — do not run this case
    * `## N-I <shells> …`, `## BUG <shells> …`, `## OK <shells> …` — the
      expectation for a shell that is not bash. Bash is the oracle here, so
      these are dropped; a multiline one is consumed to `## END` so its body
      does not fall through into the script.
    * `## compare_shells:`, `## oils_failures_allowed:`, `## tags:`, … —
      file- or case-level metadata we have no use for

  The script is kept byte-for-byte between its first and last non-blank line.
  Only whole blank lines at either end — the file's layout, not the case's —
  are dropped: `$LINENO`, `set -x` traces and bash's own `line N` diagnostics
  count from the first surviving line, and a trailing space on the last
  command is part of what the case tests.

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
      :expected_stderr,
      :expected_status,
      :skip_reason,
      :line_number
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            script: String.t(),
            expected_stdout: String.t() | nil,
            expected_stderr: String.t() | nil,
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
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> extract_test_cases([])
    |> Enum.reverse()
  end

  defp extract_test_cases([], acc), do: acc

  defp extract_test_cases([{"#### " <> name, line_num} | rest], acc) do
    {body, remaining} = Enum.split_while(rest, fn {line, _} -> not case_header?(line) end)
    extract_test_cases(remaining, [build_test_case(name, line_num, body) | acc])
  end

  defp extract_test_cases([_line | rest], acc), do: extract_test_cases(rest, acc)

  defp case_header?("#### " <> _), do: true
  defp case_header?(_), do: false

  defp build_test_case(name, line_num, body) do
    {script_lines, expectations} =
      collect(body, [], %{stdout: nil, stderr: nil, status: 0, skip: nil})

    %TestCase{
      name: name,
      script: script(script_lines),
      expected_stdout: expectations.stdout,
      expected_stderr: expectations.stderr,
      expected_status: expectations.status,
      skip_reason: expectations.skip,
      line_number: line_num
    }
  end

  # One pass over a case body, sorting each line into the script or into an
  # expectation. Script lines and directives interleave freely.
  defp collect([], script, exp), do: {Enum.reverse(script), exp}

  defp collect([{"## stdout: " <> value, _} | rest], script, exp),
    do: collect(rest, script, %{exp | stdout: value <> "\n"})

  defp collect([{"## stderr: " <> value, _} | rest], script, exp),
    do: collect(rest, script, %{exp | stderr: value <> "\n"})

  defp collect([{"## stdout-json: " <> json, _} | rest], script, exp),
    do: collect(rest, script, %{exp | stdout: parse_json_string(json)})

  defp collect([{"## stderr-json: " <> json, _} | rest], script, exp),
    do: collect(rest, script, %{exp | stderr: parse_json_string(json)})

  defp collect([{"## status: " <> value, _} | rest], script, exp),
    do: collect(rest, script, %{exp | status: value |> String.trim() |> String.to_integer()})

  defp collect([{"## SKIP" <> reason, _} | rest], script, exp),
    do: collect(rest, script, %{exp | skip: skip_reason(reason)})

  defp collect([{"## " <> _ = line, _} | rest], script, exp) do
    case block_opener(line) do
      :stdout ->
        {stdout, rest} = collect_block(rest, [])
        collect(rest, script, %{exp | stdout: stdout})

      :stderr ->
        {stderr, rest} = collect_block(rest, [])
        collect(rest, script, %{exp | stderr: stderr})

      # Another shell's multiline expectation: drop it, body and all.
      :other_shell ->
        {_ignored, rest} = collect_block(rest, [])
        collect(rest, script, exp)

      nil ->
        collect(rest, script, exp)
    end
  end

  defp collect([{line, _} | rest], script, exp), do: collect(rest, [line | script], exp)

  # `## STDOUT:` and `## STDERR:` open a block; so does the same suffix behind a
  # shell annotation (`## N-I dash STDOUT:`). Trailing spaces after the colon
  # are common in the corpus and mean nothing.
  defp block_opener(line) do
    case String.trim_trailing(line) do
      "## STDOUT:" -> :stdout
      "## STDERR:" -> :stderr
      trimmed -> if String.ends_with?(trimmed, ["STDOUT:", "STDERR:"]), do: :other_shell
    end
  end

  # A block runs to `## END` (spelled `## END:` in a few upstream files). A
  # missing terminator ends it at the next directive rather than eating the
  # rest of the case.
  defp collect_block([], acc), do: {block_text(acc), []}

  defp collect_block([{"## END" <> _, _} | rest], acc), do: {block_text(acc), rest}

  defp collect_block([{"## " <> _, _} | _] = lines, acc), do: {block_text(acc), lines}

  defp collect_block([{"#### " <> _, _} | _] = lines, acc), do: {block_text(acc), lines}

  defp collect_block([{line, _} | rest], acc), do: collect_block(rest, [line | acc])

  defp block_text([]), do: ""
  defp block_text(acc), do: acc |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")

  # `## SKIP (unimplementable): python2 not available` and the bare
  # `## SKIP: reason` both carry their reason after the colon.
  defp skip_reason(rest) do
    case String.split(rest, ":", parts: 2) do
      [_prefix, reason] -> String.trim(reason)
      [_only] -> String.trim(rest)
    end
  end

  # Trim at line granularity, not character granularity. The blank lines that
  # frame a case belong to the file's layout; a trailing space on a command
  # belongs to the case — `#### a && b ` in shell-grammar.test.sh is testing
  # exactly that. `String.trim/1` cannot tell them apart and drops both.
  #
  # Interior blank lines stay: `$LINENO` and bash's `line N:` diagnostics are
  # counted from the first surviving line, which is what the corpus's recorded
  # expectations assume (`builtin-trap-err.test.sh` asserts `line=3`).
  defp script(lines) do
    lines
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp blank?(line), do: String.trim(line) == ""

  defp parse_json_string(json) do
    # Handle simple JSON string escapes
    json
    |> String.trim()
    |> String.trim("\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end
end
