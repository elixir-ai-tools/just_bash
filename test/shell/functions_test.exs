defmodule JustBash.Shell.FunctionsTest do
  @moduledoc """
  Tests for shell function side effects.

  In real bash, functions run in the current shell — not a subshell.
  Side effects (variable assignments, export, filesystem changes via
  redirections, function redefinitions) are visible to the caller.
  Only `local` variables are scoped to the function.
  Positional parameters ($1, $2, $#, $@, $*) are scoped to the function
  and restored when the function returns.
  """
  use ExUnit.Case, async: true

  describe "function environment side effects" do
    test "variable set inside function is visible to caller" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        myfunc() {
          GLOBAL_VAR="set_in_func"
        }
        GLOBAL_VAR="original"
        myfunc
        echo "GLOBAL_VAR=$GLOBAL_VAR"
        """)

      assert result.stdout == "GLOBAL_VAR=set_in_func\n"
    end

    test "export inside function is visible to caller" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        myfunc() {
          export FUNC_VAR="from_func"
        }
        myfunc
        echo "FUNC_VAR=$FUNC_VAR"
        """)

      assert result.stdout == "FUNC_VAR=from_func\n"
    end

    test "multiple variables set inside function persist" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        setup() {
          A="alpha"
          B="beta"
          C="gamma"
        }
        setup
        echo "$A $B $C"
        """)

      assert result.stdout == "alpha beta gamma\n"
    end

    test "function modifies existing variable" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        increment() {
          COUNT=$((COUNT + 1))
        }
        COUNT=0
        increment
        increment
        increment
        echo "COUNT=$COUNT"
        """)

      assert result.stdout == "COUNT=3\n"
    end

    test "local variable does NOT leak to caller" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        myfunc() {
          local LOCAL_VAR="local_only"
          GLOBAL_VAR="set_in_func"
        }
        myfunc
        echo "GLOBAL_VAR=$GLOBAL_VAR"
        echo "LOCAL_VAR=$LOCAL_VAR"
        """)

      assert result.stdout == "GLOBAL_VAR=set_in_func\nLOCAL_VAR=\n"
    end
  end

  describe "function positional parameter scoping" do
    test "caller positional params are restored after function call" do
      bash = JustBash.new()

      # When a script is invoked without args, $1/$2/$# should be empty/0
      # after calling a function that receives args
      {result, _} =
        JustBash.exec(bash, """
        myfunc() {
          echo "inside: $1 $2 $#"
        }
        myfunc arg1 arg2
        echo "outside: [$1] [$2] [$#]"
        """)

      assert result.stdout == "inside: arg1 arg2 2\noutside: [] [] [0]\n"
    end

    test "function args don't overwrite caller args set via set --" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        myfunc() {
          echo "func: $1"
        }
        set -- caller_arg
        myfunc func_arg
        echo "after: $1"
        """)

      assert result.stdout == "func: func_arg\nafter: caller_arg\n"
    end
  end

  describe "function filesystem side effects" do
    test "file created by redirection inside function persists" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        make_file() {
          echo "written by func" > /tmp/func_output.txt
        }
        make_file
        cat /tmp/func_output.txt
        """)

      assert result.stdout == "written by func\n"
    end

    test "file appended inside function persists" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        append_file() {
          echo "line $1" >> /tmp/log.txt
        }
        echo "start" > /tmp/log.txt
        append_file 1
        append_file 2
        cat /tmp/log.txt
        """)

      assert result.stdout == "start\nline 1\nline 2\n"
    end
  end

  describe "function redefines other functions" do
    test "function defined inside another function persists" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        inner() { echo "original inner"; }
        outer() { inner() { echo "redefined inner"; }; }
        inner
        outer
        inner
        """)

      assert result.stdout == "original inner\nredefined inner\n"
    end
  end

  describe "combined side effects" do
    test "function sets env and writes file" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        init() {
          STATUS="initialized"
          echo "config data" > /tmp/config.txt
        }
        init
        echo "STATUS=$STATUS"
        cat /tmp/config.txt
        """)

      assert result.stdout == "STATUS=initialized\nconfig data\n"
    end

    test "env set in function visible across exec calls" do
      bash = JustBash.new()

      {_result, bash} =
        JustBash.exec(bash, """
        setup() {
          MY_SETTING="configured"
        }
        setup
        """)

      {result, _} = JustBash.exec(bash, "echo $MY_SETTING")
      assert result.stdout == "configured\n"
    end
  end
end
