defmodule JustBash.Commands.DevNullTest do
  @moduledoc """
  `/dev/null` as a file operand must agree with `/dev/null` as a redirect.

  Issue #78: PR #74 taught the shell to service `cmd < /dev/null`, but the
  path still did not exist in the VFS, so every command that resolved it as
  an operand failed. The rows below are the table from that issue, checked
  against GNU coreutils.
  """
  use ExUnit.Case, async: true

  describe "operand and redirect agree" do
    test "cat /dev/null and cat < /dev/null both exit 0 with empty stdout" do
      bash = JustBash.new()

      {as_operand, _} = JustBash.exec(bash, "cat /dev/null; echo rc=$?")
      {as_redirect, _} = JustBash.exec(bash, "cat < /dev/null; echo rc=$?")

      assert as_operand.stdout == "rc=0\n"
      assert as_operand.stderr == ""
      assert as_redirect.stdout == "rc=0\n"
      assert as_redirect.stderr == ""
    end

    test "echo > /dev/null still discards stdout" do
      {result, _} = JustBash.exec(JustBash.new(), "echo hello > /dev/null")

      assert result.exit_code == 0
      assert result.stdout == ""
      assert result.stderr == ""
    end
  end

  describe "the #78 command table" do
    test "sort /dev/null exits 0" do
      {result, _} = JustBash.exec(JustBash.new(), "sort /dev/null")

      assert result.exit_code == 0
      assert result.stdout == ""
      assert result.stderr == ""
    end

    test "wc -l /dev/null counts zero lines" do
      {result, _} = JustBash.exec(JustBash.new(), "wc -l /dev/null")

      assert result.exit_code == 0
      assert result.stdout == "      0 /dev/null\n"
      assert result.stderr == ""
    end

    test "head /dev/null exits 0" do
      {result, _} = JustBash.exec(JustBash.new(), "head /dev/null")

      assert result.exit_code == 0
      assert result.stdout == ""
      assert result.stderr == ""
    end

    test "cp /dev/null /out truncates /out" do
      bash = JustBash.new(files: %{"/out" => "old content\n"})
      {result, bash} = JustBash.exec(bash, "cp /dev/null /out")

      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /out")
      assert cat.stdout == ""
    end

    test "cp /dev/null /out creates an empty /out when it is missing" do
      {result, bash} = JustBash.exec(JustBash.new(), "cp /dev/null /out")

      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /out")
      assert cat.stdout == ""
    end

    test "test -e /dev/null is true" do
      {result, _} = JustBash.exec(JustBash.new(), "test -e /dev/null; echo rc=$?")

      assert result.stdout == "rc=0\n"
      assert result.stderr == ""
    end
  end

  describe "writes are discarded" do
    test "a write through tee does not make later reads return those bytes" do
      {result, bash} = JustBash.exec(JustBash.new(), "echo secret | tee /dev/null")

      assert result.exit_code == 0
      assert result.stdout == "secret\n"

      {cat, _} = JustBash.exec(bash, "cat /dev/null")
      assert cat.stdout == ""
      assert cat.exit_code == 0
    end

    test "cp of a real file onto /dev/null discards without creating a regular file" do
      bash = JustBash.new(files: %{"/src" => "payload\n"})
      {result, bash} = JustBash.exec(bash, "cp /src /dev/null")

      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /dev/null")
      assert cat.stdout == ""
    end
  end
end
