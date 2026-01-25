defmodule JustBash.BashComparison.EnvironmentTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "basic variables" do
    test "simple assignment and echo" do
      compare_bash("MY_VAR=hello; echo $MY_VAR")
    end

    test "assignment with quotes" do
      compare_bash(~s|VAR="hello world"; echo "$VAR"|)
    end

    test "empty assignment" do
      compare_bash("EMPTY=; echo \"[$EMPTY]\"")
    end

    test "variable expansion in assignment" do
      compare_bash("BASE=hello; DERIVED=${BASE}_world; echo $DERIVED")
    end

    test "append pattern" do
      compare_bash("X=start; X=${X}_end; echo $X")
    end
  end

  describe "export" do
    test "export existing variable" do
      compare_bash("VAR=value; export VAR; echo $VAR")
    end

    test "export with value" do
      compare_bash("export NEW_VAR=newvalue; echo $NEW_VAR")
    end

    test "multiple export" do
      compare_bash("export A=1 B=2 C=3; echo $A $B $C")
    end

    test "export persists to subshell" do
      compare_bash("export PERSIST=value; result=$(echo $PERSIST); echo $result")
    end
  end

  describe "unset" do
    test "unset variable" do
      compare_bash("VAR=value; echo before:$VAR; unset VAR; echo after:[$VAR]")
    end

    test "unset nonexistent" do
      compare_bash("unset NONEXISTENT; echo $?")
    end

    test "unset then reassign" do
      compare_bash("VAR=first; unset VAR; VAR=second; echo $VAR")
    end
  end

  describe "printenv" do
    test "printenv specific variable" do
      compare_bash("export MYVAR=testval; printenv MYVAR")
    end

    test "printenv nonexistent" do
      compare_bash("printenv NONEXISTENT_VAR_12345; echo $?")
    end
  end

  describe "subshell isolation" do
    test "subshell variable not visible in parent" do
      compare_bash("OUTER=outer; (OUTER=modified); echo $OUTER")
    end

    test "parent variable visible in subshell" do
      compare_bash("PARENT=parent; result=$(echo $PARENT); echo $result")
    end

    test "command substitution inherits env" do
      compare_bash("VAR=hello; echo $(echo $VAR)")
    end
  end

  describe "default environment" do
    test "HOME exists" do
      compare_bash("test -n \"$HOME\" && echo yes || echo no")
    end

    test "PWD exists" do
      compare_bash("test -n \"$PWD\" && echo yes || echo no")
    end

    test "PATH exists" do
      compare_bash("test -n \"$PATH\" && echo yes || echo no")
    end
  end

  describe "empty vs unset" do
    test "empty uses default with colon" do
      compare_bash("EMPTY=; echo \"${EMPTY:-default}\"")
    end

    test "unset uses default" do
      compare_bash("echo \"${NOTSET:-default}\"")
    end

    test "empty without colon does not use default" do
      compare_bash("EMPTY=; echo \"${EMPTY-default}\"")
    end

    test "unset without colon uses default" do
      compare_bash("echo \"${NOTSET-default}\"")
    end
  end

  describe "special variables" do
    test "$? after true" do
      compare_bash("true; echo $?")
    end

    test "$? after false" do
      compare_bash("false; echo $?")
    end

    test "$$ is numeric" do
      compare_bash("test $$ -gt 0 && echo yes || echo no")
    end
  end

  describe "IFS" do
    test "default IFS word splitting" do
      compare_bash("words='a b c'; for w in $words; do echo $w; done")
    end

    test "custom IFS" do
      compare_bash("IFS=':'; str='a:b:c'; for w in $str; do echo $w; done")
    end
  end
end
