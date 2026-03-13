defmodule JustBash.BashComparison.StandaloneTest do
  @moduledoc """
  Tests that were previously in the compare_bash test files but use
  custom assertions rather than simple output comparison.

  These tests exercise behavior that doesn't fit the fixture model
  (e.g. checking error substrings, exit codes independently, or
  testing JustBash-specific behavior without a bash reference).
  """

  use ExUnit.Case, async: true

  describe "arithmetic: division by zero" do
    test "integer division by zero produces non-zero exit" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1/0))")

      assert result.exit_code == 1
      assert result.stdout <> result.stderr =~ "division by 0"
    end

    test "modulo by zero produces non-zero exit" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1%0))")

      assert result.exit_code == 1
      assert result.stdout <> result.stderr =~ "division by 0"
    end
  end

  describe "find: edge cases" do
    test "find nonexistent path reports error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "find /tmp/nonexistent_dir_12345 2>&1")

      assert result.stdout <> result.stderr =~ "No such file or directory"
    end
  end

  describe "redirection: file descriptor manipulation" do
    test "close stdout syntax is accepted without crashing" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello >&-; echo done")

      # Should complete (exit 0) even if close fd isn't fully implemented
      assert result.exit_code == 0
    end
  end

  describe "command substitution: nested quotes" do
    test "quoted command substitution with inner escaped quotes" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world"})
      script = "echo \"$(cat /test.txt | grep \"hello\")\""
      {result, _} = JustBash.exec(bash, script)

      assert result.stdout == "hello world\n"
    end
  end

  describe "grep: recursive search" do
    test "grep -r searches directories recursively" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "hello world\n",
            "/data/b.txt" => "goodbye world\n",
            "/data/subdir/c.txt" => "hello again\n"
          }
        )

      {result, _} = JustBash.exec(bash, "grep -r 'hello' /data")

      assert result.exit_code == 0
      assert result.stdout =~ "/data/a.txt"
      assert result.stdout =~ "/data/subdir/c.txt"
      assert result.stdout =~ "hello world"
      assert result.stdout =~ "hello again"
      refute result.stdout =~ "goodbye"
    end

    test "grep -r with no matches returns exit 1" do
      bash = JustBash.new(files: %{"/data/a.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "grep -r 'xyz' /data")

      assert result.exit_code == 1
    end

    test "grep -r combined with other flags" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "Hello World\n",
            "/data/b.txt" => "hello world\n"
          }
        )

      {result, _} = JustBash.exec(bash, "grep -ri 'hello' /data")

      assert result.exit_code == 0
      assert result.stdout =~ "/data/a.txt"
      assert result.stdout =~ "/data/b.txt"
    end

    test "grep -R is same as -r" do
      bash = JustBash.new(files: %{"/data/a.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "grep -R 'hello' /data")

      assert result.exit_code == 0
      assert result.stdout =~ "hello"
    end

    test "grep -r on file works like regular grep" do
      bash = JustBash.new(files: %{"/data/a.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, "grep -r 'hello' /data/a.txt")

      assert result.exit_code == 0
      assert result.stdout =~ "hello"
    end

    test "grep -rl lists only matching files" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "hello\n",
            "/data/b.txt" => "world\n",
            "/data/c.txt" => "hello world\n"
          }
        )

      {result, _} = JustBash.exec(bash, "grep -rl 'hello' /data")

      assert result.exit_code == 0
      assert result.stdout =~ "/data/a.txt"
      assert result.stdout =~ "/data/c.txt"
      refute result.stdout =~ "/data/b.txt"
    end
  end
end
