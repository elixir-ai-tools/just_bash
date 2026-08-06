defmodule JustBash.SpecTest.ParserTest do
  @moduledoc """
  #70 item 7 calls `lib/just_bash/spec_test/parser.ex` untrustworthy and lists
  four defects. Nothing calls the parser, so nothing caught them:

    * `:skip` was never assigned, so `Runner`'s skip guard was dead code and
      all 247 SKIP-marked cases ran. Worse, Oils writes `## SKIP` *above* the
      script, and the parser stopped collecting the script at the first `##`
      line — so a SKIP-marked case ran with an empty script and "passed"
      whatever it was asked.
    * `String.trim_leading(line, "#### ")` strips the prefix *repeatedly*, so
      a name that itself begins with the header prefix loses part of itself.
    * `String.trim(script)` trimmed whitespace *characters*, so it silently
      rewrote the last command of every case whose script ends in a space —
      11 of them — while the format only means to drop the blank lines that
      frame a case.
    * `## STDERR` was never read, so the 65 cases carrying a stderr
      expectation asserted nothing about stderr.

  These run against the real corpus rather than hand-written fixtures — the
  parser's only job is to read those 136 files.
  """
  use ExUnit.Case, async: true

  alias JustBash.SpecTest.Parser
  alias JustBash.SpecTest.Parser.TestCase
  alias JustBash.SpecTest.Runner

  @cases_dir "test/command_spec_cases/bash/cases"

  defp parse!(file) do
    assert {:ok, cases} = Parser.parse_file(Path.join(@cases_dir, file))
    cases
  end

  defp fetch!(file, name) do
    cases = parse!(file)

    case Enum.find(cases, &(&1.name == name)) do
      nil -> flunk("no case named #{inspect(name)} in #{file}")
      %TestCase{} = test_case -> test_case
    end
  end

  defp all_cases do
    Enum.flat_map(Path.wildcard(Path.join(@cases_dir, "*.test.sh")), fn path ->
      assert {:ok, cases} = Parser.parse_file(path)
      cases
    end)
  end

  describe "## SKIP" do
    test "the marker sets skip_reason" do
      case_ = fetch!("command-sub.test.sh", "Command Sub trailing newline removed")

      assert case_.skip_reason == "python2 not available"
    end

    test "a marker above the script does not swallow the script" do
      case_ = fetch!("command-sub.test.sh", "Command Sub trailing newline removed")

      assert case_.script == ~s|s=$(python2 -c 'print("ab\\ncd\\n")')\nargv.py "$s"|
    end

    test "every SKIP marker in the corpus produces a skip_reason" do
      markers =
        @cases_dir
        |> Path.join("*.test.sh")
        |> Path.wildcard()
        |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n")))
        |> Enum.count(&String.starts_with?(&1, "## SKIP"))

      assert markers == 247
      assert Enum.count(all_cases(), & &1.skip_reason) == markers
    end

    test "Runner does not execute a skipped case" do
      [case_] =
        Parser.parse("""
        #### skipped
        ## SKIP (unimplementable): no reason to run this
        echo ran
        ## stdout: ran
        """)

      assert %Runner.Result{skipped: true, actual_stdout: nil} = Runner.run_test_case(case_, [])
    end

    test "a skipped case is neither a pass nor a failure in the summary" do
      cases =
        Parser.parse("""
        #### skipped
        ## SKIP (unimplementable): no reason to run this
        echo ran
        ## stdout: ran

        #### runs
        echo ran
        ## stdout: ran
        """)

      summary = cases |> Runner.run_test_cases() |> Runner.summary()

      assert %{total: 1, passed: 1, failed: 0, skipped: 1, pass_rate: 100.0} = summary
    end
  end

  describe "the script" do
    test "keeps interior blank lines, which $LINENO counts" do
      case_ = fetch!("builtin-trap-err.test.sh", "trap can use original $LINENO")

      # The blank line framing the case goes; the one inside it stays, which
      # is what puts the two `false` commands on the lines the recorded
      # expectation names.
      assert case_.script == "trap 'echo line=$LINENO' ERR\n\nfalse\nfalse\necho ok"
      assert case_.expected_stdout == "line=3\nline=4\nok\n"

      lines = String.split(case_.script, "\n")
      assert Enum.at(lines, 3 - 1) == "false"
      assert Enum.at(lines, 4 - 1) == "false"
    end

    test "keeps trailing spaces on the last line" do
      case_ = fetch!("shell-grammar.test.sh", "a && b ")

      assert case_.script == "echo word_a && echo word_b "
    end

    test "String.trim/1 would rewrite the last command of 11 corpus cases" do
      rewritten = Enum.count(all_cases(), &(String.trim(&1.script) != &1.script))

      assert rewritten == 11
    end

    test "never contains a directive line" do
      offenders =
        Enum.filter(all_cases(), fn case_ ->
          case_.script
          |> String.split("\n")
          |> Enum.any?(&String.starts_with?(&1, "## "))
        end)

      assert offenders == []
    end

    test "a multiline block for another shell does not leak into it" do
      case_ = fetch!("redirect.test.sh", "Parsing of x={myvar} and related cases")

      # The case is followed by `## BUG mksh/ash STDOUT:` and `## N-I dash
      # STDOUT:` blocks whose bodies are lines of expected output, not shell.
      refute case_.script =~ "x={myvar}\n0\nx={myvar}"
      assert String.ends_with?(case_.script, "echo $((myvar-starting_fd))")
    end
  end

  describe "## STDERR" do
    test "a multiline block is read" do
      case_ = fetch!("array-literal.test.sh", "non-index forms of element (BashAssoc)")

      assert case_.expected_stderr ==
               "bash: line 2: a: 2: must use subscript when assigning associative array\n" <>
                 "bash: line 2: a: 3: must use subscript when assigning associative array\n" <>
                 "bash: line 2: a: 4: must use subscript when assigning associative array\n"
    end

    test "a case may assert on stderr alone" do
      case_ = fetch!("redirect.test.sh", ">& and <& are the same")

      assert case_.expected_stderr == "one\ntwo\n"
      assert case_.expected_stdout == nil
    end

    test "the corpus's 65 stderr expectations are all read" do
      assert Enum.count(all_cases(), & &1.expected_stderr) == 65
    end

    test "Runner fails a case whose stderr diverges" do
      [case_] =
        Parser.parse("""
        #### stderr
        echo out
        ## STDOUT:
        out
        ## END
        ## STDERR:
        expected
        ## END
        """)

      refute Runner.run_test_case(case_, []).passed
    end
  end

  describe "the case header" do
    test "strips the prefix once, not repeatedly" do
      # No corpus case is spelled this way today, which is why the repeated
      # strip went unnoticed; `String.trim_leading/2` removes every leading
      # occurrence of its argument, not just the first.
      assert [%TestCase{name: "#### nested"}] = Parser.parse("#### #### nested\ntrue\n")
    end
  end

  describe "the whole corpus" do
    test "parses into 2728 cases across 136 files" do
      assert length(Path.wildcard(Path.join(@cases_dir, "*.test.sh"))) == 136
      assert length(all_cases()) == 2728
    end
  end
end
