defmodule JustBash.BashComparison.ControlFlowTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "for loop basics" do
    test "for loop with list" do
      compare_bash("for i in a b c; do echo $i; done")
    end

    test "for loop with range" do
      compare_bash("for i in {1..3}; do echo $i; done")
    end

    test "for loop with quoted string" do
      compare_bash("for i in 'a b' c; do echo \"[$i]\"; done")
    end

    test "for loop with variable" do
      compare_bash("items='x y z'; for i in $items; do echo $i; done")
    end

    test "for loop empty list" do
      compare_bash("for i in; do echo $i; done; echo done")
    end

    test "for loop single item" do
      compare_bash("for i in only; do echo $i; done")
    end

    test "for loop with glob pattern" do
      compare_bash("""
      mkdir -p /tmp/fortest
      touch /tmp/fortest/a.txt /tmp/fortest/b.txt
      for f in /tmp/fortest/*.txt; do basename $f; done | sort
      """)
    end
  end

  describe "while loop" do
    test "basic while" do
      compare_bash("x=3; while [ $x -gt 0 ]; do echo $x; x=$((x-1)); done")
    end

    test "while with false condition" do
      compare_bash("while false; do echo never; done; echo done")
    end

    test "while count up" do
      compare_bash("x=0; while [ $x -lt 3 ]; do echo $x; x=$((x+1)); done")
    end

    test "while with command condition" do
      compare_bash("x=0; while test $x -lt 2; do echo $x; x=$((x+1)); done")
    end
  end

  describe "until loop" do
    test "basic until" do
      compare_bash("x=0; until [ $x -ge 3 ]; do echo $x; x=$((x+1)); done")
    end

    test "until with true condition" do
      compare_bash("until true; do echo never; done; echo done")
    end

    test "until count down" do
      compare_bash("x=3; until [ $x -eq 0 ]; do echo $x; x=$((x-1)); done")
    end
  end

  describe "break statement" do
    test "break in for loop" do
      compare_bash("for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then break; fi; echo $i; done")
    end

    test "break in while loop" do
      compare_bash(
        "x=0; while true; do x=$((x+1)); if [ $x -ge 3 ]; then break; fi; echo $x; done"
      )
    end

    test "break with level 1" do
      compare_bash("for i in 1 2 3; do if [ $i -eq 2 ]; then break 1; fi; echo $i; done")
    end

    test "break with level 2 in nested loops" do
      compare_bash("""
      for i in 1 2; do
        for j in a b c; do
          if [ "$j" = "b" ]; then break 2; fi
          echo "$i$j"
        done
        echo "inner done"
      done
      echo "outer done"
      """)
    end

    test "break only inner loop" do
      compare_bash("""
      for i in 1 2; do
        for j in a b c; do
          if [ "$j" = "b" ]; then break; fi
          echo "$i$j"
        done
        echo "i=$i done"
      done
      """)
    end
  end

  describe "continue statement" do
    test "continue in for loop" do
      compare_bash("for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then continue; fi; echo $i; done")
    end

    test "continue in while loop" do
      compare_bash(
        "x=0; while [ $x -lt 5 ]; do x=$((x+1)); if [ $x -eq 3 ]; then continue; fi; echo $x; done"
      )
    end

    test "continue with level 1" do
      compare_bash("for i in 1 2 3; do if [ $i -eq 2 ]; then continue 1; fi; echo $i; done")
    end

    test "continue with level 2 in nested loops" do
      compare_bash("""
      for i in 1 2 3; do
        echo "i=$i start"
        for j in a b c; do
          if [ "$j" = "b" ]; then continue 2; fi
          echo "$i$j"
        done
        echo "i=$i end"
      done
      """)
    end
  end

  describe "if statements" do
    test "if true" do
      compare_bash("if true; then echo yes; fi")
    end

    test "if false with else" do
      compare_bash("if false; then echo yes; else echo no; fi")
    end

    test "if elif else" do
      compare_bash(
        "x=2; if [ $x -eq 1 ]; then echo one; elif [ $x -eq 2 ]; then echo two; else echo other; fi"
      )
    end

    test "multiple elif" do
      compare_bash(
        "x=3; if [ $x -eq 1 ]; then echo 1; elif [ $x -eq 2 ]; then echo 2; elif [ $x -eq 3 ]; then echo 3; else echo x; fi"
      )
    end

    test "nested if" do
      compare_bash("x=1; y=2; if [ $x -eq 1 ]; then if [ $y -eq 2 ]; then echo both; fi; fi")
    end

    test "if with command" do
      compare_bash("if echo test >/dev/null; then echo ok; fi")
    end

    test "if with negation" do
      compare_bash("if ! false; then echo not false; fi")
    end
  end

  describe "case statement" do
    test "simple case" do
      compare_bash("x=b; case $x in a) echo A;; b) echo B;; esac")
    end

    test "case with default" do
      compare_bash("x=z; case $x in a) echo A;; b) echo B;; *) echo default;; esac")
    end

    test "case with pattern" do
      compare_bash("x=hello; case $x in h*) echo starts with h;; *) echo other;; esac")
    end

    test "case with multiple patterns" do
      compare_bash("x=y; case $x in a|b|c) echo abc;; x|y|z) echo xyz;; esac")
    end

    test "case with bracket pattern" do
      compare_bash("x=test; case $x in [tT]*) echo starts with t;; esac")
    end

    test "case empty match" do
      compare_bash("x=''; case $x in '') echo empty;; *) echo not empty;; esac")
    end

    test "case no match" do
      compare_bash("x=nomatch; case $x in a) echo A;; b) echo B;; esac; echo done")
    end

    test "case with question mark" do
      compare_bash("x=ab; case $x in a?) echo 'a + one char';; *) echo other;; esac")
    end
  end

  describe "compound commands" do
    test "command list with semicolons" do
      compare_bash("echo a; echo b; echo c")
    end

    test "command list with &&" do
      compare_bash("true && echo success")
    end

    test "command list with || (short circuit)" do
      compare_bash("true || echo should not print")
    end

    test "command list with || (fallback)" do
      compare_bash("false || echo fallback")
    end

    test "combined && and ||" do
      compare_bash("true && echo yes || echo no")
    end

    test "combined && and || with false" do
      compare_bash("false && echo yes || echo no")
    end

    test "subshell" do
      compare_bash("(echo in subshell; x=1); echo $x")
    end

    test "command group" do
      compare_bash("{ echo a; echo b; }")
    end
  end

  describe "exit codes" do
    test "successful command" do
      compare_bash("true; echo $?")
    end

    test "failed command" do
      compare_bash("false; echo $?")
    end

    test "last command in pipeline" do
      compare_bash("true | false; echo $?")
    end

    test "custom exit code" do
      compare_bash("(exit 42); echo $?")
    end
  end
end
