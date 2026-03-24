defmodule JustBash.Limit.ResourceExhaustionTest do
  @moduledoc """
  Adversarial tests that verify resource limits protect the BEAM.

  Each test simulates a resource exhaustion vector that would hang or OOM
  a production system without limits. Tests use strict limits and short
  timeouts to prove the sandbox terminates quickly.
  """
  use ExUnit.Case, async: true

  # Every test must complete well under this. If any test takes even close
  # to this long, the limit enforcement failed.
  @moduletag timeout: 5_000

  defp strict_bash(overrides \\ []) do
    defaults = [
      max_steps: 1_000,
      max_output_bytes: 10_000,
      max_file_bytes: 10_000,
      max_regex_pattern_bytes: 100,
      max_exec_depth: 5
    ]

    # max_iterations must exceed max_steps so step limit fires first
    JustBash.new(limits: Keyword.merge(defaults, overrides), max_iterations: 10_000)
  end

  describe "CPU exhaustion" do
    test "infinite while loop" do
      bash = strict_bash()
      {result, _} = JustBash.exec(bash, "while true; do :; done")
      assert result.exit_code == 1
    end

    test "infinite until loop" do
      bash = strict_bash()
      {result, _} = JustBash.exec(bash, "until false; do :; done")
      assert result.exit_code == 1
    end

    test "for loop over huge expansion" do
      bash = strict_bash()
      {result, _} = JustBash.exec(bash, "for i in {1..10000}; do echo $i; done")
      assert result.exit_code == 1
    end

    test "recursive function (fork bomb pattern)" do
      bash = strict_bash()
      {result, _} = JustBash.exec(bash, "bomb() { bomb; }; bomb")
      assert result.exit_code == 1
    end

    test "nested loop multiplication" do
      bash = strict_bash()

      {result, _} =
        JustBash.exec(bash, """
        for i in $(seq 1 100); do
          for j in $(seq 1 100); do
            echo "$i $j"
          done
        done
        """)

      assert result.exit_code == 1
    end
  end

  describe "memory exhaustion via output" do
    test "echo in tight loop" do
      bash = strict_bash(max_output_bytes: 1_000)

      {result, _} =
        JustBash.exec(bash, "while true; do echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; done")

      assert result.exit_code == 1
      assert result.stderr =~ "limit"
    end

    test "cat /dev/zero equivalent (repeated printf)" do
      bash = strict_bash(max_output_bytes: 500)
      {result, _} = JustBash.exec(bash, ~s(while true; do printf '%0100d' 0; done))
      assert result.exit_code == 1
    end

    test "yes command flood" do
      bash = strict_bash(max_output_bytes: 500)
      {result, _} = JustBash.exec(bash, "yes")
      assert result.exit_code == 1
    end
  end

  describe "memory exhaustion via filesystem" do
    test "write oversized file" do
      bash = strict_bash(max_file_bytes: 100)
      big = String.duplicate("X", 200)
      {result, _} = JustBash.exec(bash, ~s(echo -n "#{big}" > /tmp/evil.txt))
      assert result.exit_code == 1
      assert result.stderr =~ "file size limit"
    end

    test "append loop to grow file past limit" do
      bash = strict_bash(max_file_bytes: 100)

      {result, _} =
        JustBash.exec(
          bash,
          "for i in $(seq 1 100); do echo AAAAAAAAAA >> /tmp/grow.txt; done"
        )

      assert result.exit_code == 1
    end
  end

  describe "ReDoS (regex denial of service)" do
    test "oversized regex pattern in sed" do
      bash = strict_bash(max_regex_pattern_bytes: 50)
      evil = String.duplicate("(a+)+", 20)
      {result, _} = JustBash.exec(bash, "echo x | sed 's/#{evil}/y/'")
      assert result.exit_code == 1
      assert result.stderr =~ "regex pattern size limit"
    end

    test "oversized regex pattern in grep" do
      bash = strict_bash(max_regex_pattern_bytes: 50)
      evil = String.duplicate("a", 100)
      {result, _} = JustBash.exec(bash, "echo x | grep '#{evil}'")
      assert result.exit_code == 1
    end

    test "oversized regex in awk" do
      bash = strict_bash(max_regex_pattern_bytes: 50)
      evil = String.duplicate("a", 100)
      {result, _} = JustBash.exec(bash, "echo x | awk '/#{evil}/{print}'")
      assert result.exit_code == 1
    end

    test "oversized regex in [[ =~ ]]" do
      bash = strict_bash(max_regex_pattern_bytes: 50)
      evil = String.duplicate("a", 100)
      {result, _} = JustBash.exec(bash, ~s([[ "x" =~ #{evil} ]]))
      assert result.exit_code == 1
    end

    test "oversized regex in parameter expansion" do
      bash = strict_bash(max_regex_pattern_bytes: 50)
      evil = String.duplicate("a", 100)
      {result, _} = JustBash.exec(bash, ~s(x=hello; echo "${x/#{evil}/world}"))
      assert result.exit_code == 1
    end
  end

  describe "eval/source nesting bomb" do
    test "deeply nested eval" do
      bash = strict_bash(max_exec_depth: 3)
      {result, _} = JustBash.exec(bash, "eval 'eval \"eval \\\"echo deep\\\"\"'")
      assert result.exit_code == 1
      assert result.stderr =~ "nesting depth"
    end

    test "eval calling eval in loop" do
      bash = strict_bash(max_exec_depth: 3)

      {result, _} =
        JustBash.exec(
          bash,
          ~s(for i in 1 2 3 4 5 6 7 8 9 10; do eval "eval 'eval echo \\$i'"; done)
        )

      assert result.exit_code == 1
    end
  end

  describe "combined attacks" do
    test "fork bomb + output flood" do
      bash = strict_bash()

      {result, _} =
        JustBash.exec(bash, """
        flood() {
          while true; do
            echo AAAAAAAAAA
            flood
          done
        }
        flood
        """)

      assert result.exit_code == 1
    end

    test "script terminates and returns promptly" do
      # Key production safety test: even with an adversarial script,
      # exec returns quickly and the BEAM is unharmed.
      bash = strict_bash()
      start = System.monotonic_time(:millisecond)

      {_result, _} = JustBash.exec(bash, "while true; do while true; do echo x; done; done")

      elapsed = System.monotonic_time(:millisecond) - start
      # Must complete in under 1 second — proves we're not spinning
      assert elapsed < 1_000, "adversarial script took #{elapsed}ms, should be under 1000ms"
    end
  end
end
