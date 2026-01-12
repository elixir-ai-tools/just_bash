defmodule JustBash.Shell.ControlFlowTest do
  use ExUnit.Case, async: true

  describe "if statement" do
    test "if with true condition" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "if true; then echo yes; fi")
      assert result.stdout == "yes\n"
      assert result.exit_code == 0
    end

    test "if with false condition" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "if false; then echo yes; fi")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "if-else with true condition" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "if true; then echo yes; else echo no; fi")
      assert result.stdout == "yes\n"
    end

    test "if-else with false condition" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "if false; then echo yes; else echo no; fi")
      assert result.stdout == "no\n"
    end

    test "if-elif-else" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "if false; then echo a; elif true; then echo b; else echo c; fi")

      assert result.stdout == "b\n"
    end

    test "if with command condition" do
      bash = JustBash.new(files: %{"/file.txt" => "content\n"})
      {result, _} = JustBash.exec(bash, "if cat /file.txt; then echo exists; fi")
      assert result.stdout == "content\nexists\n"
    end
  end

  describe "for loop" do
    test "for loop with word list" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "for x in a b c; do echo $x; done")
      assert result.stdout == "a\nb\nc\n"
    end

    test "for loop variable persists" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "for x in a b c; do echo $x; done")
      assert result.stdout == "a\nb\nc\n"

      {result2, _} = JustBash.exec(bash, "echo $x")
      assert result2.stdout == "c\n"
    end

    test "for loop with empty list" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "for x in; do echo $x; done")
      assert result.stdout == ""
    end

    test "for loop with variable expansion" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "LIST=\"1 2 3\"")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "for i in $LIST; do echo $i; done")
      assert result2.stdout == "1\n2\n3\n"
    end
  end

  describe "while loop" do
    test "while with false condition never runs" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "while false; do echo loop; done")
      assert result.stdout == ""
    end

    test "while loop runs while condition true" do
      bash = JustBash.new(files: %{"/counter" => "x"})

      {result, _} =
        JustBash.exec(bash, """
        while cat /counter; do
          rm /counter
        done
        echo done
        """)

      assert result.stdout == "xdone\n"
    end

    test "while with test condition" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        i=0
        while [ $i -lt 3 ]; do
          echo $i
          i=$((i + 1))
        done
        """)

      assert result.stdout == "0\n1\n2\n"
    end
  end

  describe "until loop" do
    test "until with true condition never runs" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "until true; do echo loop; done")
      assert result.stdout == ""
    end

    test "until runs until condition succeeds" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        until cat /flag; do
          touch /flag
        done
        echo done
        """)

      assert result.stdout == "done\n"
    end
  end

  describe "test command" do
    test "test string equality" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "test foo = foo && echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "test foo = bar && echo yes")
      assert result2.stdout == ""
    end

    test "[ ] syntax" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "[ foo = foo ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "string inequality" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "[ foo != bar ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "numeric comparisons" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "[ 5 -eq 5 ] && echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "[ 5 -lt 10 ] && echo yes")
      assert result2.stdout == "yes\n"

      {result3, _} = JustBash.exec(bash, "[ 10 -gt 5 ] && echo yes")
      assert result3.stdout == "yes\n"

      {result4, _} = JustBash.exec(bash, "[ 5 -ne 3 ] && echo yes")
      assert result4.stdout == "yes\n"
    end

    test "string empty/non-empty tests" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "[ -z \"\" ] && echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "[ -n foo ] && echo yes")
      assert result2.stdout == "yes\n"
    end

    test "file existence tests" do
      bash = JustBash.new(files: %{"/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "[ -e /file.txt ] && echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "[ -f /file.txt ] && echo yes")
      assert result2.stdout == "yes\n"

      {result3, _} = JustBash.exec(bash, "[ -d /home ] && echo yes")
      assert result3.stdout == "yes\n"
    end

    test "negation with !" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "[ ! -e /nonexistent ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "if with test condition" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=5")

      {result, _} =
        JustBash.exec(bash, """
        if [ $x -eq 5 ]; then
          echo equal
        else
          echo not_equal
        fi
        """)

      assert result.stdout == "equal\n"
    end

    test "test -le less or equal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "[ 3 -le 3 ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "test -ge greater or equal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "[ 5 -ge 3 ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "test -s file has size" do
      bash = JustBash.new(files: %{"/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "[ -s /file.txt ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "test -s empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "[ -s /empty.txt ] || echo empty")
      assert result.stdout == "empty\n"
    end

    test "test string comparison <" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "test \"abc\" '<' \"def\" && echo yes")
      assert result.stdout == "yes\n"
    end

    test "test string comparison >" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "test \"xyz\" '>' \"abc\" && echo yes")
      assert result.stdout == "yes\n"
    end

    test "test -L detects symlink" do
      bash = JustBash.new(files: %{"/target.txt" => "content"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      {result, _} = JustBash.exec(bash, "[ -L /link.txt ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "test -L returns false for regular file" do
      bash = JustBash.new(files: %{"/regular.txt" => "content"})
      {result, _} = JustBash.exec(bash, "[ -L /regular.txt ] || echo no")
      assert result.stdout == "no\n"
    end

    test "test -h detects symlink (alias for -L)" do
      bash = JustBash.new(files: %{"/target.txt" => "content"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      {result, _} = JustBash.exec(bash, "[ -h /link.txt ] && echo yes")
      assert result.stdout == "yes\n"
    end
  end
end
