defmodule JustBash.BashComparison.SpecialVariablesTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "exit code variable $?" do
    test "exit code after true" do
      compare_bash("true; echo $?")
    end

    test "exit code after false" do
      compare_bash("false; echo $?")
    end

    test "exit code after command" do
      compare_bash("echo hello >/dev/null; echo $?")
    end

    test "exit code after failed command" do
      compare_bash("test -f /nonexistent_file_12345; echo $?")
    end

    test "exit code from subshell" do
      compare_bash("(exit 42); echo $?")
    end

    test "exit code preserved across commands" do
      compare_bash("false; x=$?; echo $x")
    end
  end

  describe "argument count $#" do
    test "zero arguments" do
      compare_bash("set --; echo $#")
    end

    test "one argument" do
      compare_bash("set -- a; echo $#")
    end

    test "multiple arguments" do
      compare_bash("set -- a b c; echo $#")
    end

    test "many arguments" do
      compare_bash("set -- 1 2 3 4 5 6 7 8 9 10; echo $#")
    end

    test "after shift" do
      compare_bash("set -- a b c; shift; echo $#")
    end

    test "after shift 2" do
      compare_bash("set -- a b c d e; shift 2; echo $#")
    end
  end

  describe "positional parameters $1 $2 etc" do
    test "first positional" do
      compare_bash("set -- first second third; echo $1")
    end

    test "second positional" do
      compare_bash("set -- first second third; echo $2")
    end

    test "third positional" do
      compare_bash("set -- first second third; echo $3")
    end

    test "undefined positional" do
      compare_bash("set -- a b; echo $5")
    end

    test "positional after shift" do
      compare_bash("set -- a b c d; shift; echo $1 $2 $3")
    end

    test "ninth positional" do
      compare_bash("set -- 1 2 3 4 5 6 7 8 9 10; echo $9")
    end

    test "all positional in string" do
      compare_bash("set -- a b c; echo \"1=$1 2=$2 3=$3\"")
    end
  end

  describe "all arguments $@ and $*" do
    test "$@ unquoted" do
      compare_bash("set -- a b c; echo $@")
    end

    test "$* unquoted" do
      compare_bash("set -- a b c; echo $*")
    end

    test "$@ quoted" do
      compare_bash("set -- a b c; echo \"$@\"")
    end

    test "$* quoted" do
      compare_bash("set -- a b c; echo \"$*\"")
    end

    test "$@ with spaces in args" do
      compare_bash("set -- 'a b' 'c d' e; for arg in \"$@\"; do echo \"[$arg]\"; done")
    end

    test "$* with spaces in args" do
      compare_bash("set -- 'a b' 'c d' e; echo \"$*\"")
    end

    test "empty $@" do
      compare_bash("set --; echo \"[$@]\"")
    end

    test "empty $*" do
      compare_bash("set --; echo \"[$*]\"")
    end

    test "$@ in for loop" do
      compare_bash("set -- x y z; for i in \"$@\"; do echo $i; done")
    end

    test "$* as single string" do
      compare_bash("set -- one two three; x=\"$*\"; echo $x")
    end
  end

  describe "special variables in functions" do
    test "function $# differs from script $#" do
      compare_bash("""
      set -- a b
      f() { echo "func args: $#"; }
      f x y z
      echo "script args: $#"
      """)
    end

    test "function positional parameters" do
      compare_bash("""
      f() { echo "$1 $2 $3"; }
      f one two three
      """)
    end

    test "function $@ iteration" do
      compare_bash("""
      f() { for arg in "$@"; do echo "arg: $arg"; done; }
      f alpha beta gamma
      """)
    end
  end

  describe "negation with !" do
    test "negate true" do
      compare_bash("! true; echo $?")
    end

    test "negate false" do
      compare_bash("! false; echo $?")
    end

    test "negate command" do
      compare_bash("! test -f /nonexistent; echo $?")
    end
  end

  describe "process-related special variables" do
    test "RANDOM produces numbers" do
      compare_bash("x=$RANDOM; test -n \"$x\" && echo ok || echo empty")
    end
  end

  describe "PIPESTATUS array" do
    test "PIPESTATUS after simple pipeline" do
      compare_bash("echo hello | cat; echo ${PIPESTATUS[0]} ${PIPESTATUS[1]}")
    end

    test "PIPESTATUS with failed first command" do
      compare_bash("false | cat; echo ${PIPESTATUS[0]} ${PIPESTATUS[1]}")
    end

    test "PIPESTATUS with failed last command" do
      compare_bash("echo hello | false; echo ${PIPESTATUS[0]} ${PIPESTATUS[1]}")
    end

    test "PIPESTATUS all elements" do
      compare_bash("true | false | true; echo ${PIPESTATUS[@]}")
    end

    test "PIPESTATUS single command" do
      compare_bash("true; echo ${PIPESTATUS[0]}")
    end

    test "PIPESTATUS reset after each pipeline" do
      compare_bash("false | true; x=\"${PIPESTATUS[@]}\"; true; echo \"$x\" ${PIPESTATUS[@]}")
    end

    test "PIPESTATUS length" do
      compare_bash("echo a | cat | cat; echo ${#PIPESTATUS[@]}")
    end
  end
end
