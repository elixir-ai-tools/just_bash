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

  Two more, found reviewing the first round of fixes:

    * every `## OK bash …` / `## BUG bash …` / `## N-I bash …` annotation was
      dropped as "another shell's expectation". It is the opposite: the
      unannotated default records osh, and an annotation naming bash is
      bash's own recorded behaviour. 440 such lines cover 323 of the 2728
      cases, which were pinned to a shell we are not implementing.
    * `## stdout:` with nothing after the colon — the format's spelling of
      "one empty line" — was not recognised, so those cases asserted nothing
      and passed whatever they printed.

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

  describe "a shell annotation naming bash" do
    test "a multiline STDOUT block overrides the unannotated expectation" do
      # append.test.sh:134 records `## stdout-json: ""` / `## status: 2` for
      # osh, then `## OK bash STDOUT:` -> `['1', '2 3']` with status 0. Bash is
      # the oracle, so the annotation is the expectation.
      case_ = fetch!("append.test.sh", "Try to append list to element")

      assert case_.expected_stdout == "['1', '2 3']\n"
      assert case_.expected_status == 0
    end

    test "overrides one key at a time, leaving the others at their default" do
      # `## OK bash status: 0` is a single line with no stdout beside it, so
      # the default `## stdout: hi` still stands.
      case_ = fetch!("loop.test.sh", "bad arg to break")

      assert case_.expected_stdout == "hi\n"
      assert case_.expected_status == 128
    end

    test "just-bash wins over bash" do
      # loop.test.sh:273 carries `## BUG bash STDOUT: a\n--` / status 0 and
      # then this repo's own `## OK just-bash STDOUT: a` / status 1.
      case_ = fetch!("loop.test.sh", "too many args to continue")

      assert case_.expected_stdout == "a\n"
      assert case_.expected_status == 1
    end

    test "just-bash wins over bash for a multiline block" do
      case_ = fetch!("var-op-bash.test.sh", "Array expansion with nullary var op @Q")

      # `## OK bash STDOUT:` records the associative array reversed; the
      # `## OK just-bash STDOUT:` below it records our insertion order.
      assert case_.expected_stdout =~ ~s(["'hello'", "'world'", "'osh'", "'ysh'"])
      refute case_.expected_stdout =~ ~s(["'ysh'", "'osh'")
    end

    test "an annotation naming another shell is still dropped" do
      [case_] =
        Parser.parse("""
        #### annotated
        echo hi
        ## stdout: hi
        ## status: 0
        ## OK dash stdout: bye
        ## OK dash status: 3
        """)

      assert case_.expected_stdout == "hi\n"
      assert case_.expected_status == 0
    end

    test "bash-2 is a different shell from bash" do
      # assign-extended.test.sh carries both `## OK bash STDOUT:` and
      # `## OK bash-2 STDOUT:`; bash-2 is bash 2.x, not our oracle.
      case_ = fetch!("assign-extended.test.sh", "declare -p arr")

      assert case_.expected_stdout =~ "declare -A test_arr6=([a]=\"1\" [b]=\"2\" [c]=\"3\" )"
    end

    test "a non-bash multiline annotation body still does not leak into the script" do
      [case_] =
        Parser.parse("""
        #### annotated
        echo hi
        ## STDOUT:
        hi
        ## END
        ## OK dash STDOUT:
        not shell
        ## END
        """)

      assert case_.script == "echo hi"
      assert case_.expected_stdout == "hi\n"
    end

    test "every bash-keyed status annotation in the corpus is the case's status" do
      annotated = bash_status_annotations()

      # An independent read of the same 136 files: 124 cases spell bash's exit
      # status as an annotation, and every one of them must survive parsing.
      assert map_size(annotated) == 124

      mismatched =
        for {{file, name}, status} <- annotated,
            case_ = fetch!(file, name),
            case_.expected_status != status,
            do: {file, name, case_.expected_status, status}

      assert mismatched == []
    end

    test "the corpus's 440 bash-keyed annotations cover 323 cases in 89 files" do
      by_case = bash_annotation_lines()

      assert by_case |> Map.values() |> List.flatten() |> length() == 440
      assert map_size(by_case) == 323
      assert by_case |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 89
    end
  end

  describe "a bare directive value" do
    # `## stdout:` with nothing after the colon is how the format spells an
    # expected single empty line — `echo $unset` prints one.
    for {file, name} <- [
          {"sh-func.test.sh", "Locals don't leak"},
          {"var-op-strip.test.sh", "Remove const suffix from undefined"},
          {"redirect-command.test.sh", "Redirect in command sub"},
          {"assign.test.sh", "Empty env binding"}
        ] do
      test "#{file} #{inspect(name)} expects one empty line, not nothing" do
        case_ = fetch!(unquote(file), unquote(name))

        assert case_.expected_stdout == "\n"
      end
    end

    test "a bare ## stderr: is read the same way" do
      [case_] =
        Parser.parse("""
        #### bare stderr
        echo x >&2
        ## stderr:
        """)

      assert case_.expected_stderr == "\n"
    end

    test "Runner fails a case whose bare stdout expectation diverges" do
      # Before the bare spelling was recognised, expected_stdout stayed nil and
      # `check_output(nil, _)` passed the case whatever it printed.
      [case_] =
        Parser.parse("""
        #### leaks
        echo leaked
        ## stdout:
        """)

      refute Runner.run_test_case(case_, []).passed
    end
  end

  describe "the whole corpus" do
    test "parses into 2728 cases across 136 files" do
      assert length(Path.wildcard(Path.join(@cases_dir, "*.test.sh"))) == 136
      assert length(all_cases()) == 2728
    end

    test "2562 cases carry a stdout expectation and only 59 assert nothing" do
      # These counts are the corpus-wide guard on every directive spelling the
      # parser claims to read: drop one and they move. A case that asserts
      # nothing at all passes vacuously, so the second number is the one that
      # decides whether a ratchet built on this parser means anything.
      cases = all_cases()

      assert Enum.count(cases, & &1.expected_stdout) == 2562
      assert Enum.count(cases, &(&1.expected_status != 0)) == 239
      assert Enum.count(cases, &asserts_nothing?/1) == 59
    end
  end

  defp asserts_nothing?(case_) do
    is_nil(case_.expected_stdout) and is_nil(case_.expected_stderr) and
      case_.expected_status == 0 and is_nil(case_.skip_reason)
  end

  # An independent reader of the corpus, deliberately not sharing code with the
  # parser: split each file on its `#### ` headers and keep the annotation lines
  # whose shell list names bash or just-bash.
  @annotation ~r{^## (?:OK|BUG|N-I)(?:-\d+)?\s+(\S+)\s+(.*)$}

  defp bash_annotation_lines do
    for {file, name, body} <- raw_cases(),
        lines = Enum.filter(body, &bash_keyed?/1),
        lines != [],
        into: %{},
        do: {{file, name}, lines}
  end

  defp bash_status_annotations do
    for {key, lines} <- bash_annotation_lines(),
        statuses = Enum.flat_map(lines, &annotated_status/1),
        statuses != [],
        into: %{},
        do: {key, List.last(statuses)}
  end

  defp annotated_status(line) do
    case Regex.run(~r{^## (?:OK|BUG|N-I)(?:-\d+)?\s+\S+\s+status:\s*(\d+)\s*$}, line) do
      [_line, status] -> [String.to_integer(status)]
      nil -> []
    end
  end

  defp bash_keyed?(line) do
    case Regex.run(@annotation, line) do
      [_line, shells, _keyed] -> Enum.any?(String.split(shells, "/"), &(&1 in ~w(bash just-bash)))
      nil -> false
    end
  end

  defp raw_cases do
    Enum.flat_map(Path.wildcard(Path.join(@cases_dir, "*.test.sh")), fn path ->
      file = Path.basename(path)

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce([], fn
        "#### " <> name, acc -> [{file, name, []} | acc]
        _line, [] -> []
        line, [{f, n, body} | rest] -> [{f, n, [line | body]} | rest]
      end)
      |> Enum.map(fn {f, n, body} -> {f, n, Enum.reverse(body)} end)
    end)
  end
end
