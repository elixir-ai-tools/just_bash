defmodule JustBash.Commands.UnknownFlagsTest do
  @moduledoc """
  A flag a command does not implement must be reported, never absorbed.

  Absorbing it is the worst available failure: `sort -Q file` used to treat
  `-Q` as a filename, read nothing, and exit 0, so the caller was told the
  empty result was the file's sorted contents.
  """
  use ExUnit.Case, async: true

  alias JustBash.Commands.Registry

  defp bash, do: JustBash.new(files: %{"/f.txt" => "a\nb\nc\n"})

  describe "commands sharing JustBash.FlagParser" do
    # The exact pair from issue #68, checked against GNU coreutils 9: both name
    # the offending character and point at --help, and sort exits 2 where uniq
    # exits 1. Only grep prints a Usage line on a bad option; coreutils does not.
    test "sort reports an unknown short flag instead of returning nothing" do
      {result, _} = JustBash.exec(bash(), "sort -Q /f.txt")

      assert result.exit_code == 2
      assert result.stdout == ""

      assert result.stderr ==
               "sort: invalid option -- 'Q'\nTry 'sort --help' for more information.\n"
    end

    test "uniq reports an unknown short flag instead of returning nothing" do
      {result, _} = JustBash.exec(bash(), "uniq -Z /f.txt")

      assert result.exit_code == 1
      assert result.stdout == ""

      assert result.stderr ==
               "uniq: invalid option -- 'Z'\nTry 'uniq --help' for more information.\n"
    end

    # `-q` is a real GNU head flag that is not implemented here. Rejecting it
    # names the actual problem; the old message ("cannot open '-q' for
    # reading") blamed a file that was never on the command line.
    test "head names the flag, not a file it invented" do
      {result, _} = JustBash.exec(bash(), "head -q /f.txt")

      assert result.exit_code == 1
      assert result.stdout == ""

      assert result.stderr ==
               "head: invalid option -- 'q'\nTry 'head --help' for more information.\n"

      refute result.stderr =~ "cannot open"
    end

    test "tail names the flag, not a file it invented" do
      {result, _} = JustBash.exec(bash(), "tail -q /f.txt")

      assert result.exit_code == 1
      assert result.stdout == ""

      assert result.stderr ==
               "tail: invalid option -- 'q'\nTry 'tail --help' for more information.\n"
    end

    # `ls -Q` used to exit 1 *and still print the listing*, so the exit code
    # and the output disagreed about whether the command had run.
    test "ls rejects an unknown flag without printing a listing" do
      {result, _} = JustBash.exec(bash(), "ls -Q /")

      assert result.exit_code == 2
      assert result.stdout == ""
      assert result.stderr == "ls: invalid option -- 'Q'\nTry 'ls --help' for more information.\n"
    end

    test "cp rejects an unknown flag before copying anything" do
      {result, after_bash} = JustBash.exec(bash(), "cp -Z /f.txt /g.txt")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "cp: invalid option -- 'Z'\nTry 'cp --help' for more information.\n"

      {check, _} = JustBash.exec(after_bash, "cat /g.txt")
      assert check.exit_code == 1
    end

    test "grep rejects an unknown flag instead of searching for it" do
      {result, _} = JustBash.exec(bash(), "grep -Z a /f.txt")

      assert result.exit_code == 2
      assert result.stdout == ""

      assert result.stderr ==
               "grep: invalid option -- 'Z'\n" <>
                 "Usage: grep [OPTION]... PATTERNS [FILE]...\n" <>
                 "Try 'grep --help' for more information.\n"
    end

    # GNU reports the offending character out of a cluster, not the cluster.
    test "a cluster is reported by the character that is not implemented" do
      {result, _} = JustBash.exec(bash(), "sort -rQ /f.txt")

      assert result.exit_code == 2
      assert result.stderr =~ "sort: invalid option -- 'Q'\n"
    end

    # A long option is named in full: `invalid option -- '-'` identifies nothing.
    test "an unknown long option is named in full" do
      {result, _} = JustBash.exec(bash(), "sort --jb-not-a-flag /f.txt")

      assert result.exit_code == 2

      assert result.stderr ==
               "sort: unrecognized option '--jb-not-a-flag'\n" <>
                 "Try 'sort --help' for more information.\n"
    end

    test "a value flag with nothing after it is a missing argument, not a file" do
      {result, _} = JustBash.exec(bash(), "head -n")

      assert result.exit_code == 1
      assert result.stdout == ""

      assert result.stderr ==
               "head: option requires an argument -- 'n'\n" <>
                 "Try 'head --help' for more information.\n"
    end

    # `--` still ends option parsing, so an option-shaped operand after it is
    # a filename, not a flag to reject.
    test "an option-shaped operand after -- is not rejected as a flag" do
      {result, _} = JustBash.exec(bash(), "sort -- -Q")

      refute result.stderr =~ "invalid option"
    end

    # A lone `-` is not option-shaped, so it stays an operand. (Reading it as
    # stdin is a separate gap in sort, untouched here.)
    test "a lone dash is still an operand" do
      {result, _} = JustBash.exec(bash(), "printf 'b\\na\\n' | sort -")

      assert result.exit_code == 0
      refute result.stderr =~ "invalid option"
    end
  end

  describe "tr" do
    test "rejects an unknown character inside a flag cluster" do
      {result, _} = JustBash.exec(bash(), "echo abc | tr -dX b")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "tr: invalid option -- 'X'\nTry 'tr --help' for more information.\n"
    end

    test "reports the first unknown character of a cluster" do
      {result, _} = JustBash.exec(bash(), "echo abc | tr -dQZ b")

      assert result.exit_code == 1
      assert result.stderr =~ "tr: invalid option -- 'Q'\n"
    end

    # A single unknown character used to fall past the flag clauses and become
    # one of tr's character sets, so `tr -x b` translated nothing and said so
    # with exit 0.
    test "a single unknown flag is not mistaken for a character set" do
      {result, _} = JustBash.exec(bash(), "echo abc | tr -x b")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "tr: invalid option -- 'x'\nTry 'tr --help' for more information.\n"
    end

    test "an unknown long option is named in full" do
      {result, _} = JustBash.exec(bash(), "echo abc | tr --jb-not-a-flag b")

      assert result.exit_code == 1
      assert result.stderr =~ "tr: unrecognized option '--jb-not-a-flag'\n"
    end

    test "implemented flags still work" do
      {result, _} = JustBash.exec(bash(), "echo abc | tr -d b")

      assert result.exit_code == 0
      assert result.stdout == "ac\n"
    end

    # `-` is not option-shaped on its own, and a set may legitimately contain
    # characters that look like flags once `--` has ended option parsing.
    test "a dash is still usable as a character set" do
      {result, _} = JustBash.exec(bash(), "echo a-b | tr -- '-' '_'")

      assert result.exit_code == 0
      assert result.stdout == "a_b\n"
    end
  end

  describe "flag values are not coerced" do
    # `parse_value/1` used to turn every integer-looking value into an integer,
    # so `sort -t 1` handed String.split/2 the number 1 and crashed the shell.
    test "sort -t takes a one-character delimiter, not a number" do
      bash = JustBash.new(files: %{"/f.txt" => "b1x\na1y\n"})
      {result, _} = JustBash.exec(bash, "sort -t 1 -k2 /f.txt")

      assert result.exit_code == 0
      assert result.stdout == "b1x\na1y\n"
    end

    test "head -n still takes a count" do
      {result, _} = JustBash.exec(bash(), "head -n 2 /f.txt")

      assert result.exit_code == 0
      assert result.stdout == "a\nb\n"
    end
  end

  describe "the whole registry" do
    @probe_flags ["--jb-not-a-flag", "-Z"]

    # Every name in `Commands.Registry`, classified by what it does with a flag
    # it does not implement. The table is compared to observed behaviour as a
    # whole, so a new command cannot join the registry without being classified
    # and a command cannot change category unnoticed.
    #
    #   :strict   - non-zero exit with a diagnostic on stderr. What every
    #               option-parsing command should do.
    #   :quiet    - non-zero exit with no diagnostic. These three parse no
    #               options at all; bash is equally silent.
    #   :operand  - exit 0 is correct: bash also treats the argument as data.
    #               `echo -Z` prints `-Z`, `test -Z` is a non-empty string.
    #   :absorbed - STILL WRONG. Exits 0 with the flag ignored, exactly the way
    #               `sort -Q` did. These are the hand-rolled `parse_args`
    #               commands that issue #68 explicitly defers migrating onto
    #               FlagParser (migrating first would have spread the bug, not
    #               fixed it). Listed by name so the list can only shrink.
    @classification %{
      "." => :strict,
      ":" => :operand,
      "[" => :absorbed,
      "arch" => :absorbed,
      "awk" => :absorbed,
      "base64" => :strict,
      "basename" => :absorbed,
      "break" => :absorbed,
      "cat" => :strict,
      "cd" => :strict,
      "chmod" => :strict,
      "chown" => :strict,
      "comm" => :strict,
      "command" => :strict,
      "continue" => :absorbed,
      "cp" => :strict,
      "curl" => :strict,
      "cut" => :strict,
      "date" => :strict,
      "declare" => :absorbed,
      "diff" => :strict,
      "dirname" => :absorbed,
      "du" => :strict,
      "echo" => :operand,
      "env" => :strict,
      "eval" => :strict,
      "exit" => :quiet,
      "expand" => :strict,
      "export" => :absorbed,
      "false" => :quiet,
      "file" => :strict,
      "find" => :strict,
      "fold" => :strict,
      "getopts" => :strict,
      "grep" => :strict,
      "head" => :strict,
      "hostname" => :absorbed,
      "id" => :absorbed,
      "jq" => :strict,
      "ln" => :strict,
      "local" => :absorbed,
      "ls" => :strict,
      "markdown" => :strict,
      "md" => :strict,
      "md5sum" => :strict,
      "mkdir" => :absorbed,
      "mktemp" => :absorbed,
      "mv" => :strict,
      "nl" => :strict,
      "nproc" => :absorbed,
      "od" => :strict,
      "paste" => :strict,
      "printenv" => :absorbed,
      "printf" => :absorbed,
      "pwd" => :absorbed,
      "read" => :quiet,
      "readlink" => :strict,
      "realpath" => :strict,
      "return" => :absorbed,
      "rev" => :absorbed,
      "rm" => :strict,
      "sed" => :strict,
      "seq" => :strict,
      "set" => :strict,
      "sha256sum" => :strict,
      "shasum" => :strict,
      "shift" => :strict,
      "sleep" => :absorbed,
      "sort" => :strict,
      "source" => :strict,
      "stat" => :strict,
      "tac" => :absorbed,
      "tail" => :strict,
      "tee" => :strict,
      "test" => :operand,
      "touch" => :absorbed,
      "tr" => :strict,
      "trap" => :strict,
      "tree" => :strict,
      "true" => :operand,
      "type" => :strict,
      "typeset" => :absorbed,
      "uname" => :absorbed,
      "uniq" => :strict,
      "unset" => :absorbed,
      "wc" => :strict,
      "wget" => :strict,
      "which" => :strict,
      "whoami" => :absorbed,
      "xargs" => :strict,
      "xxd" => :strict,
      "yes" => :operand
    }

    test "no command silently accepts a flag it does not implement" do
      observed = Map.new(Registry.list(), fn name -> {name, classify(name)} end)
      expected = Map.new(@classification, fn {name, kind} -> {name, observable(kind)} end)

      assert observed == expected
    end

    # A diagnostic nobody can attribute is barely better than none, so a
    # rejection has to name the program it came from.
    test "a rejecting command names itself in the diagnostic" do
      for {name, :strict} <- @classification, flag <- @probe_flags do
        {result, _} = JustBash.exec(bash(), "#{name} #{flag}")
        module = Registry.get(name)
        canonical = hd(module.names())

        assert String.starts_with?(result.stderr, ["bash: ", "#{name}: ", "#{canonical}: "]),
               "#{name} #{flag} exited #{result.exit_code} with unattributable stderr " <>
                 inspect(result.stderr)
      end
    end

    # :operand and :absorbed are the same observation - the command exits 0 -
    # and differ only in whether that is correct. The distinction is carried by
    # the table above so that fixing an :absorbed command forces an edit here.
    defp observable(:operand), do: :exit_zero
    defp observable(:absorbed), do: :exit_zero
    defp observable(other), do: other

    defp classify(name) do
      @probe_flags
      |> Enum.map(&probe(name, &1))
      |> Enum.uniq()
      |> case do
        [single] -> single
        both -> both
      end
    end

    defp probe(name, flag) do
      {result, _} = JustBash.exec(bash(), "#{name} #{flag}")

      cond do
        result.exit_code == 0 -> :exit_zero
        result.stderr == "" -> :quiet
        true -> :strict
      end
    end
  end
end
