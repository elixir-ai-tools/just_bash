defmodule JustBash.Shell.RedirectionsTest do
  use ExUnit.Case, async: true

  describe "redirections" do
    test "redirect stdout to file with >" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "echo hello > /output.txt")
      assert result.stdout == ""

      {result2, _} = JustBash.exec(bash, "cat /output.txt")
      assert result2.stdout == "hello\n"
    end

    test "append stdout to file with >>" do
      bash = JustBash.new(files: %{"/output.txt" => "first\n"})
      {result, bash} = JustBash.exec(bash, "echo second >> /output.txt")
      assert result.stdout == ""

      {result2, _} = JustBash.exec(bash, "cat /output.txt")
      assert result2.stdout == "first\nsecond\n"
    end

    test "redirect to /dev/null" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello > /dev/null")
      assert result.stdout == ""
    end

    test "multiple redirections" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "echo hello > /out.txt")
      {result2, bash2} = JustBash.exec(bash, "echo world >> /out.txt")
      assert result.stdout == ""
      assert result2.stdout == ""

      {result3, _} = JustBash.exec(bash2, "cat /out.txt")
      assert result3.stdout == "hello\nworld\n"
    end

    test "redirect with variable expansion" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "FILE=/output.txt")
      {result, bash} = JustBash.exec(bash, "echo content > $FILE")
      assert result.stdout == ""

      {result2, _} = JustBash.exec(bash, "cat $FILE")
      assert result2.stdout == "content\n"
    end
  end
end
