defmodule JustBash.Shell.MaxCallDepthTest do
  @moduledoc """
  Tests for max_call_depth — protection against unbounded shell function recursion.

  Without a call-depth limit, recursive shell functions grow the BEAM process
  heap without bound and can OOM-kill the entire node. These tests verify that
  the interpreter enforces a configurable depth limit and terminates runaway
  recursion with a clear error message and non-zero exit code.
  """
  use ExUnit.Case, async: true

  describe "simple recursion" do
    test "direct self-recursion is stopped at the default depth limit" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        f() { f; }
        f
        """)

      assert result.exit_code != 0
      assert result.stderr =~ "maximum call depth exceeded"
    end

    test "direct self-recursion is stopped at a custom depth limit" do
      bash = JustBash.new(security: [max_call_depth: 5])

      {result, _} =
        JustBash.exec(bash, """
        count=0
        f() { count=$((count + 1)); f; }
        f
        echo "count=$count"
        """)

      assert result.stderr =~ "maximum call depth exceeded"
      # echo runs after the failed function, so exit_code is 0
      assert result.stdout == "count=5\n"
    end
  end

  describe "pipe recursion (fork bomb pattern)" do
    test "pipe recursion is stopped" do
      bash = JustBash.new(security: [max_call_depth: 10])

      {result, _} =
        JustBash.exec(bash, """
        bomb() { bomb | bomb; }
        bomb
        """)

      assert result.exit_code != 0
      assert result.stderr =~ "maximum call depth exceeded"
    end

    test "classic fork bomb syntax is stopped" do
      bash = JustBash.new(security: [max_call_depth: 10])

      # :(){ :|:& };: — the & is ignored (background not implemented),
      # but the pipe recursion must still be caught
      {result, _} = JustBash.exec(bash, ":(){ :|:& };:")

      assert result.exit_code != 0
      assert result.stderr =~ "maximum call depth exceeded"
    end
  end

  describe "mutual recursion" do
    test "mutually recursive functions are stopped" do
      bash = JustBash.new(security: [max_call_depth: 10])

      {result, _} =
        JustBash.exec(bash, """
        a() { b; }
        b() { a; }
        a
        """)

      assert result.exit_code != 0
      assert result.stderr =~ "maximum call depth exceeded"
    end
  end

  describe "legitimate deep calls" do
    test "recursion within the limit succeeds" do
      bash = JustBash.new(security: [max_call_depth: 20])

      {result, _} =
        JustBash.exec(bash, """
        countdown() {
          local n=$1
          if [ "$n" -le 0 ]; then
            echo "done"
            return
          fi
          countdown $((n - 1))
        }
        countdown 10
        """)

      assert result.exit_code == 0
      assert result.stdout == "done\n"
    end

    test "recursion exactly at the limit succeeds" do
      # max_call_depth: 5 means up to 5 nested function calls.
      # depth(4) -> depth(3) -> depth(2) -> depth(1) -> depth(0) = 5 calls
      bash = JustBash.new(security: [max_call_depth: 5])

      {result, _} =
        JustBash.exec(bash, """
        depth() {
          local n=$1
          if [ "$n" -le 0 ]; then
            echo "bottom"
            return
          fi
          depth $((n - 1))
        }
        depth 4
        """)

      assert result.exit_code == 0
      assert result.stdout == "bottom\n"
    end

    test "recursion one past the limit fails" do
      # max_call_depth: 5, depth(5) needs 6 calls -> exceeds limit
      bash = JustBash.new(security: [max_call_depth: 5])

      {result, _} =
        JustBash.exec(bash, """
        depth() {
          local n=$1
          if [ "$n" -le 0 ]; then
            echo "bottom"
            return
          fi
          depth $((n - 1))
        }
        depth 5
        """)

      assert result.stderr =~ "maximum call depth exceeded"
    end
  end

  describe "execution continues after depth error" do
    test "commands after a depth-exceeded function still run" do
      bash = JustBash.new(security: [max_call_depth: 5])

      {result, _} =
        JustBash.exec(bash, """
        f() { f; }
        f
        echo "after"
        """)

      assert result.stderr =~ "maximum call depth exceeded"
      assert result.stdout =~ "after"
    end
  end

  describe "sequential calls do not accumulate depth" do
    test "many sequential top-level calls succeed within a small limit" do
      bash = JustBash.new(security: [max_call_depth: 5])

      {result, _} =
        JustBash.exec(bash, """
        f() { echo "ok"; }
        f; f; f; f; f; f; f; f; f; f
        """)

      assert result.exit_code == 0
      assert result.stdout == String.duplicate("ok\n", 10)
    end

    test "sequential calls after a depth error do not inherit inflated depth" do
      bash = JustBash.new(security: [max_call_depth: 5])

      {result, _} =
        JustBash.exec(bash, """
        boom() { boom; }
        ok() { echo "ok"; }
        boom
        ok; ok; ok; ok; ok; ok; ok; ok; ok; ok
        """)

      assert result.stderr =~ "maximum call depth exceeded"
      assert result.exit_code == 0
      assert result.stdout == String.duplicate("ok\n", 10)
    end
  end
end
