defmodule JustBash.LimitTest do
  use ExUnit.Case, async: true

  alias JustBash.Limit

  describe "Limit.new/1" do
    test "default preset" do
      limits = Limit.new(:default)
      assert limits.max_steps == 100_000
      assert limits.max_output_bytes == 1_048_576
      assert limits.max_value_bytes == 1_048_576
    end

    test "strict preset" do
      limits = Limit.new(:strict)
      assert limits.max_steps == 10_000
      assert limits.max_value_bytes == 65_536
    end

    test "relaxed preset" do
      limits = Limit.new(:relaxed)
      assert limits.max_steps == 1_000_000
      assert limits.max_value_bytes == 10_485_760
    end

    test "custom keyword list merges with defaults" do
      limits = Limit.new(max_steps: 42)
      assert limits.max_steps == 42
      assert limits.max_output_bytes == 1_048_576
      assert limits.max_value_bytes == 1_048_576
    end

    test "false disables limits" do
      assert Limit.new(false) == nil
    end

    test "rejects unknown keys" do
      assert_raise ArgumentError, ~r/unknown limit keys/, fn ->
        Limit.new(max_frobbles: 5)
      end
    end

    test "rejects non-positive values" do
      assert_raise ArgumentError, ~r/positive integers/, fn ->
        Limit.new(max_steps: 0)
      end
    end
  end

  describe "Limit.concat!/3" do
    test "concatenates when the result fits" do
      bash = JustBash.new(limits: [max_value_bytes: 10])
      assert Limit.concat!(bash, "hello", "wor") == "hellowor"
    end

    test "allows a result right at the bound" do
      bash = JustBash.new(limits: [max_value_bytes: 10])
      assert Limit.concat!(bash, "hello", "world") == "helloworld"
    end

    test "raises without concatenating when the sum would exceed the bound" do
      bash = JustBash.new(limits: [max_value_bytes: 10])

      assert_raise Limit.ExceededError, ~r/value size limit exceeded \(10 bytes\)/, fn ->
        Limit.concat!(bash, "hello", "world!")
      end
    end

    test "is a no-op bound when limits are disabled" do
      bash = JustBash.new(limits: false)
      assert Limit.concat!(bash, "hello", "world") == "helloworld"
    end
  end

  describe "Limit.replace!/5" do
    test "replaces when the result fits" do
      bash = JustBash.new(limits: [max_value_bytes: 10])
      assert Limit.replace!(bash, ~r/a/, "aaa", "X", global: true) == "XXX"
    end

    test "allows a result right at the bound" do
      bash = JustBash.new(limits: [max_value_bytes: 9])
      assert Limit.replace!(bash, ~r/a/, "aaa", "XXX", global: true) == "XXXXXXXXX"
    end

    test "raises without replacing when a global replace would exceed the bound" do
      bash = JustBash.new(limits: [max_value_bytes: 10])

      assert_raise Limit.ExceededError, ~r/value size limit exceeded \(10 bytes\)/, fn ->
        Limit.replace!(bash, ~r/a/, "aaa", "XXXX", global: true)
      end
    end

    test "raises without replacing when a single replace would exceed the bound" do
      bash = JustBash.new(limits: [max_value_bytes: 10])

      assert_raise Limit.ExceededError, ~r/value size limit exceeded \(10 bytes\)/, fn ->
        Limit.replace!(bash, ~r/a/, "aaa", "XXXXXXXXXXXX", global: false)
      end
    end

    test "does not refuse a non-matching replace of a cap-sized haystack" do
      bash = JustBash.new(limits: [max_value_bytes: 10])
      assert Limit.replace!(bash, ~r/z/, "aaaaaaaaaa", "XXXX", global: true) == "aaaaaaaaaa"
    end

    test "is a no-op bound when limits are disabled" do
      bash = JustBash.new(limits: false)
      assert Limit.replace!(bash, ~r/a/, "aaa", "XXXX", global: true) == "XXXXXXXXXXXX"
    end
  end

  describe "Limit.check_value_size!/2" do
    test "accepts a byte count so callers can refuse before allocating" do
      bash = JustBash.new(limits: [max_value_bytes: 10])
      assert Limit.check_value_size!(bash, 10) == :ok

      assert_raise Limit.ExceededError, ~r/value size limit exceeded \(10 bytes\)/, fn ->
        Limit.check_value_size!(bash, 11)
      end
    end

    test "passes when limits are disabled" do
      bash = JustBash.new(limits: false)
      assert Limit.check_value_size!(bash, 1_000_000) == :ok
    end
  end

  describe "JustBash.new/1 limits option" do
    test "defaults to :default limits" do
      bash = JustBash.new()
      assert bash.limits.max_steps == 100_000
    end

    test "accepts preset atom" do
      bash = JustBash.new(limits: :strict)
      assert bash.limits.max_steps == 10_000
    end

    test "accepts keyword overrides" do
      bash = JustBash.new(limits: [max_steps: 500])
      assert bash.limits.max_steps == 500
    end

    test "false disables limits" do
      bash = JustBash.new(limits: false)
      assert bash.limits == nil
    end
  end

  describe "step limit" do
    test "stops execution when step limit exceeded" do
      bash = JustBash.new(limits: [max_steps: 5])
      {result, _bash} = JustBash.exec(bash, "echo a; echo b; echo c; echo d; echo e; echo f")
      assert result.exit_code == 1
      assert result.stderr =~ "execution step limit exceeded"
    end

    test "while loop respects step limit" do
      bash = JustBash.new(limits: [max_steps: 10])
      {result, _bash} = JustBash.exec(bash, "i=0; while true; do i=$((i+1)); done; echo $i")
      assert result.exit_code == 1
      assert result.stderr =~ "step limit"
    end

    test "for loop respects step limit" do
      bash = JustBash.new(limits: [max_steps: 3])
      {result, _bash} = JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i; done")
      assert result.exit_code == 1
      assert result.stderr =~ "step limit"
    end

    test "no limit when limits: false" do
      bash = JustBash.new(limits: false, max_iterations: 200)

      {result, _bash} =
        JustBash.exec(bash, "i=0; while [ $i -lt 100 ]; do echo $i; i=$((i+1)); done")

      assert result.exit_code == 0
    end
  end

  describe "output limit" do
    test "stops execution when output exceeds limit" do
      bash = JustBash.new(limits: [max_output_bytes: 50])

      {result, _bash} =
        JustBash.exec(bash, "i=0; while [ $i -lt 100 ]; do echo $i; i=$((i+1)); done")

      assert result.exit_code == 1
      assert result.stderr =~ "output size limit exceeded"
    end

    test "single large output triggers limit" do
      bash = JustBash.new(limits: [max_output_bytes: 10])

      {result, _bash} =
        JustBash.exec(bash, ~s(echo "this is a long output that exceeds the limit"))

      assert result.exit_code == 1
      assert result.stderr =~ "output size limit exceeded"
    end
  end

  describe "file size limit" do
    test "blocks writing files larger than limit" do
      bash = JustBash.new(limits: [max_file_bytes: 10])
      big_data = String.duplicate("x", 100)
      {result, _bash} = JustBash.exec(bash, ~s(echo -n "#{big_data}" > /tmp/big.txt))
      assert result.exit_code == 1
      assert result.stderr =~ "file size limit exceeded"
    end

    test "allows writing files within limit" do
      bash = JustBash.new(limits: [max_file_bytes: 1000])
      {result, _bash} = JustBash.exec(bash, ~s(echo "hello" > /tmp/small.txt))
      assert result.exit_code == 0
    end

    test "> /dev/./null skips the file-size cap" do
      bash = JustBash.new(limits: [max_file_bytes: 10])
      big = String.duplicate("x", 100)
      {result, bash} = JustBash.exec(bash, ~s(echo -n "#{big}" > /dev/./null))

      assert result.exit_code == 0
      assert result.stdout == ""
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /dev/null")
      assert cat.stdout == ""
    end
  end

  describe "value size limit" do
    test "stops execution when an assignment would exceed the bound" do
      bash = JustBash.new(limits: [max_value_bytes: 10])
      {result, _bash} = JustBash.exec(bash, ~s(v=abcdefghijk; echo "$v"))
      assert result.exit_code == 1
      assert result.stderr =~ "value size limit exceeded (10 bytes)"
    end

    test "allows an assignment right at the bound" do
      bash = JustBash.new(limits: [max_value_bytes: 8])
      {result, _bash} = JustBash.exec(bash, ~s(v=12345678; echo "$v"))
      assert result.exit_code == 0
      assert result.stdout == "12345678\n"
    end

    test "a normal-size assignment is untouched" do
      bash = JustBash.new(limits: [max_value_bytes: 1_000])
      {result, _bash} = JustBash.exec(bash, "v=hello; echo $v")
      assert result.exit_code == 0
      assert result.stdout == "hello\n"
    end
  end

  describe "regex pattern limit" do
    test "sed rejects oversized patterns" do
      bash = JustBash.new(limits: [max_regex_pattern_bytes: 5])
      long_pattern = String.duplicate("a", 20)
      {result, _bash} = JustBash.exec(bash, "echo hello | sed 's/#{long_pattern}/world/'")
      assert result.exit_code == 1
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "grep rejects oversized patterns" do
      bash =
        JustBash.new(
          limits: [max_regex_pattern_bytes: 5],
          files: %{"/data.txt" => "hello world"}
        )

      long_pattern = String.duplicate("a", 20)
      {result, _bash} = JustBash.exec(bash, "grep '#{long_pattern}' /data.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "awk rejects oversized patterns" do
      bash = JustBash.new(limits: [max_regex_pattern_bytes: 5])
      long_pattern = String.duplicate("a", 20)
      {result, _bash} = JustBash.exec(bash, "echo test | awk '/#{long_pattern}/{print}'")
      assert result.exit_code == 1
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "[[ =~ ]] rejects oversized patterns" do
      bash = JustBash.new(limits: [max_regex_pattern_bytes: 5])
      long_pattern = String.duplicate("a", 20)
      {result, _bash} = JustBash.exec(bash, ~s([[ "hello" =~ #{long_pattern} ]]))
      assert result.exit_code == 1
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "${var/pattern/replacement} rejects oversized patterns" do
      bash = JustBash.new(limits: [max_regex_pattern_bytes: 5])
      long_pattern = String.duplicate("a", 20)
      {result, _bash} = JustBash.exec(bash, ~s(x=hello; echo "${x/#{long_pattern}/world}"))
      assert result.exit_code == 1
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "allows patterns within limit" do
      bash = JustBash.new(limits: [max_regex_pattern_bytes: 100])
      {result, _bash} = JustBash.exec(bash, "echo hello | sed 's/hello/world/'")
      assert result.exit_code == 0
      assert result.stdout == "world\n"
    end
  end

  describe "exec depth limit" do
    test "stops deeply nested eval" do
      bash = JustBash.new(limits: [max_exec_depth: 3])
      {result, _bash} = JustBash.exec(bash, "eval 'eval \"eval \\\"echo deep\\\"\"'")
      assert result.exit_code == 1
      assert result.stderr =~ "execution nesting depth exceeded"
    end

    test "allows eval within limit" do
      bash = JustBash.new(limits: [max_exec_depth: 10])
      {result, _bash} = JustBash.exec(bash, "eval 'echo hello'")
      assert result.exit_code == 0
      assert result.stdout == "hello\n"
    end
  end

  describe "halted flag prevents further execution" do
    test "no more statements run after limit exceeded" do
      bash = JustBash.new(limits: [max_steps: 2])
      # After step limit, subsequent echos should not produce output
      {result, _bash} = JustBash.exec(bash, "echo a; echo b; echo c; echo SHOULD_NOT_APPEAR")
      refute result.stdout =~ "SHOULD_NOT_APPEAR"
    end
  end

  describe "JustBash.stats/1" do
    test "returns step count and output bytes after execution" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "echo hello")
      stats = JustBash.stats(bash)

      assert stats.steps > 0
      assert stats.output_bytes > 0
      assert stats.max_exec_depth >= 1
    end

    test "steps increase with more commands" do
      bash = JustBash.new()
      {_, bash1} = JustBash.exec(bash, "echo a")
      {_, bash2} = JustBash.exec(bash, "echo a; echo b; echo c")

      assert JustBash.stats(bash2).steps > JustBash.stats(bash1).steps
    end

    test "output bytes reflect actual output size" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, ~s(echo -n "hello"))
      stats = JustBash.stats(bash)

      assert stats.output_bytes == 5
    end

    test "loop iterations consume more steps than simple commands" do
      bash = JustBash.new()
      {_, simple} = JustBash.exec(bash, "echo done")
      {_, looped} = JustBash.exec(bash, "for i in 1 2 3 4 5; do echo $i; done")

      assert JustBash.stats(looped).steps > JustBash.stats(simple).steps
    end

    test "counters reset between top-level exec calls" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "for i in 1 2 3 4 5; do echo $i; done")
      first = JustBash.stats(bash)

      {_, bash} = JustBash.exec(bash, "echo one")
      second = JustBash.stats(bash)

      assert second.steps < first.steps
      assert second.output_bytes < first.output_bytes
    end

    test "stats work with limits disabled" do
      bash = JustBash.new(limits: false)
      {_, bash} = JustBash.exec(bash, "echo hello")
      stats = JustBash.stats(bash)

      assert stats.steps > 0
      assert stats.output_bytes > 0
      assert stats.max_exec_depth >= 1
    end

    test "returns zero stats on fresh bash" do
      bash = JustBash.new()
      stats = JustBash.stats(bash)

      assert stats == %{steps: 0, output_bytes: 0, max_exec_depth: 0}
    end
  end
end
