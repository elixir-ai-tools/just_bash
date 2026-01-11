defmodule JustBash.InterpreterTest do
  use ExUnit.Case, async: true

  describe "basic commands" do
    test "echo with multiple arguments" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo a b c")
      assert result.stdout == "a b c\n"
    end

    test "echo -n suppresses newline" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n hello")
      assert result.stdout == "hello"
    end

    test "echo -e interprets escapes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'hello\\nworld'")
      assert result.stdout == "hello\nworld\n"
    end

    test "pwd shows current directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "pwd")
      assert result.stdout == "/home/user\n"
    end

    test "true returns 0" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true")
      assert result.exit_code == 0
    end

    test "false returns 1" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "false")
      assert result.exit_code == 1
    end

    test ": (colon) is a no-op that returns 0" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ":")
      assert result.exit_code == 0
    end
  end

  describe "cd command" do
    test "cd changes directory" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "cd /tmp")
      assert result.exit_code == 0
      assert new_bash.cwd == "/tmp"
    end

    test "cd with no args goes home" do
      bash = JustBash.new(cwd: "/tmp")
      {result, new_bash} = JustBash.exec(bash, "cd")
      assert result.exit_code == 0
      assert new_bash.cwd == "/home/user"
    end

    test "cd to nonexistent directory fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cd /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end
  end

  describe "cat command" do
    test "cat reads file content" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world"})
      {result, _} = JustBash.exec(bash, "cat /test.txt")
      assert result.stdout == "hello world"
      assert result.exit_code == 0
    end

    test "cat nonexistent file fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cat /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "cat multiple files concatenates them" do
      bash = JustBash.new(files: %{"/a.txt" => "AAA", "/b.txt" => "BBB"})
      {result, _} = JustBash.exec(bash, "cat /a.txt /b.txt")
      assert result.stdout == "AAABBB"
    end
  end

  describe "ls command" do
    test "ls nonexistent directory fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ls /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end
  end

  describe "rm command" do
    test "rm nonexistent file fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "rm -f nonexistent file succeeds" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm -f /nonexistent")
      assert result.exit_code == 0
    end
  end

  describe "touch command" do
    test "touch existing file succeeds" do
      bash = JustBash.new(files: %{"/home/user/existing.txt" => "content"})
      {result, _} = JustBash.exec(bash, "touch /home/user/existing.txt")
      assert result.exit_code == 0
    end
  end

  describe "export and unset" do
    test "export sets environment variable" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "export FOO=bar")
      assert result.exit_code == 0
      assert new_bash.env["FOO"] == "bar"
    end

    test "unset removes environment variable" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, new_bash} = JustBash.exec(bash, "unset FOO")
      assert result.exit_code == 0
      refute Map.has_key?(new_bash.env, "FOO")
    end
  end

  describe "variable expansion" do
    test "simple variable expansion" do
      bash = JustBash.new(env: %{"NAME" => "world"})
      {result, _} = JustBash.exec(bash, "echo hello $NAME")
      assert result.stdout == "hello world\n"
    end

    test "undefined variable expands to empty" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello$UNDEFINED")
      assert result.stdout == "hello\n"
    end

    test "single quotes prevent expansion" do
      bash = JustBash.new(env: %{"VAR" => "value"})
      {result, _} = JustBash.exec(bash, "echo '$VAR'")
      assert result.stdout == "$VAR\n"
    end

    test "double quotes preserve variable expansion" do
      bash = JustBash.new(env: %{"VAR" => "value"})
      {result, _} = JustBash.exec(bash, ~s(echo "$VAR"))
      assert result.stdout == "value\n"
    end

    test "braced variable expansion" do
      bash = JustBash.new(env: %{"NAME" => "world"})
      {result, _} = JustBash.exec(bash, "echo ${NAME}")
      assert result.stdout == "world\n"
    end

    test "default value expansion :- when unset" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ${UNSET:-default}")
      assert result.stdout == "default\n"
    end

    test "default value expansion :- when empty" do
      bash = JustBash.new(env: %{"EMPTY" => ""})
      {result, _} = JustBash.exec(bash, "echo ${EMPTY:-default}")
      assert result.stdout == "default\n"
    end

    test "default value expansion - only when unset" do
      bash = JustBash.new(env: %{"EMPTY" => ""})
      {result, _} = JustBash.exec(bash, "echo ${EMPTY-default}")
      assert result.stdout == "\n"
    end

    test "alternative value expansion :+ when set" do
      bash = JustBash.new(env: %{"SET" => "value"})
      {result, _} = JustBash.exec(bash, "echo ${SET:+alternative}")
      assert result.stdout == "alternative\n"
    end

    test "alternative value expansion :+ when unset" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ${UNSET:+alternative}")
      assert result.stdout == "\n"
    end

    test "length expansion" do
      bash = JustBash.new(env: %{"VAR" => "hello"})
      {result, _} = JustBash.exec(bash, "echo ${#VAR}")
      assert result.stdout == "5\n"
    end

    test "special parameter $?" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true; echo $?")
      assert result.stdout == "0\n"

      {result2, _} = JustBash.exec(bash, "false; echo $?")
      assert result2.stdout == "1\n"
    end
  end

  describe "operators" do
    test "! negates exit code" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "! false")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "! true")
      assert result2.exit_code == 1
    end

    test "&& runs second command only if first succeeds" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true && echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "false && echo no")
      assert result2.stdout == ""
    end

    test "|| runs second command only if first fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "false || echo yes")
      assert result.stdout == "yes\n"

      {result2, _} = JustBash.exec(bash, "true || echo no")
      assert result2.stdout == ""
    end

    test "combined && and || operators" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true && echo a || echo b")
      assert result.stdout == "a\n"

      {result2, _} = JustBash.exec(bash, "false && echo a || echo b")
      assert result2.stdout == "b\n"
    end
  end

  describe "command substitution" do
    test "basic $(cmd) substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(echo hello)")
      assert result.stdout == "hello\n"
    end

    test "$(cmd) with multiple words" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(echo hello world)")
      assert result.stdout == "hello world\n"
    end

    test "nested command substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(echo $(echo nested))")
      assert result.stdout == "nested\n"
    end

    test "$(cmd) strips trailing newlines" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"x$(echo hello)y\"")
      assert result.stdout == "xhelloy\n"
    end

    test "$(cmd) with pwd" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(pwd)")
      assert result.stdout == "/home/user\n"
    end

    test "$(cmd) with variables" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "export FOO=bar")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "echo $(echo $FOO)")
      assert result2.stdout == "bar\n"
    end

    test "$(cmd) in variable assignment" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "DIR=$(pwd)")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "echo $DIR")
      assert result2.stdout == "/home/user\n"
    end

    test "backtick substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo `echo hello`")
      assert result.stdout == "hello\n"
    end

    test "$(cmd) with cat" do
      bash = JustBash.new(files: %{"/data/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "echo $(cat /data/file.txt)")
      assert result.stdout == "content\n"
    end

    test "$(cmd) preserves exit code context" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(true) && echo success")
      assert result.stdout == "\nsuccess\n"
    end
  end

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

  describe "arithmetic expansion" do
    test "basic arithmetic" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 + 2))")
      assert result.stdout == "3\n"
    end

    test "arithmetic with variables" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=5")
      {result, _} = JustBash.exec(bash, "echo $((x + 3))")
      assert result.stdout == "8\n"
    end

    test "arithmetic multiplication" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((3 * 4))")
      assert result.stdout == "12\n"
    end

    test "arithmetic division" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((10 / 3))")
      assert result.stdout == "3\n"
    end

    test "arithmetic modulo" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((10 % 3))")
      assert result.stdout == "1\n"
    end

    test "arithmetic comparison" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((5 > 3))")
      assert result.stdout == "1\n"

      {result2, _} = JustBash.exec(bash, "echo $((5 < 3))")
      assert result2.stdout == "0\n"
    end

    test "arithmetic in assignment" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=$((5 + 3))")
      {result, _} = JustBash.exec(bash, "echo $x")
      assert result.stdout == "8\n"
    end

    test "arithmetic increment" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=5")
      {result, _} = JustBash.exec(bash, "echo $((++x))")
      assert result.stdout == "6\n"
    end

    test "arithmetic with parentheses" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(((2 + 3) * 4))")
      assert result.stdout == "20\n"
    end

    test "arithmetic ternary operator" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 ? 10 : 20))")
      assert result.stdout == "10\n"

      {result2, _} = JustBash.exec(bash, "echo $((0 ? 10 : 20))")
      assert result2.stdout == "20\n"
    end

    test "arithmetic assignment operators" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=10")
      {result, _} = JustBash.exec(bash, "echo $((x += 5))")
      assert result.stdout == "15\n"
    end

    test "arithmetic bitwise operators" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((5 & 3))")
      assert result.stdout == "1\n"

      {result2, _} = JustBash.exec(bash, "echo $((5 | 3))")
      assert result2.stdout == "7\n"
    end

    test "negative numbers" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((-5 + 3))")
      assert result.stdout == "-2\n"
    end

    test "hex numbers" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((0xff))")
      assert result.stdout == "255\n"
    end

    test "octal numbers" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((010))")
      assert result.stdout == "8\n"
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

  describe "additional commands" do
    test "cp copies file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {result, bash} = JustBash.exec(bash, "cp /src.txt /dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "content"
    end

    test "mv moves file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {result, bash} = JustBash.exec(bash, "mv /src.txt /dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "content"

      {result3, _} = JustBash.exec(bash, "cat /src.txt")
      assert result3.exit_code == 1
    end

    test "head shows first lines" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\nline3\nline4\nline5\n"})
      {result, _} = JustBash.exec(bash, "head -n 2 /file.txt")
      assert result.stdout == "line1\nline2\n"
    end

    test "tail shows last lines" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\nline3\nline4\nline5\n"})
      {result, _} = JustBash.exec(bash, "tail -n 2 /file.txt")
      assert result.stdout == "line4\nline5\n"
    end

    test "wc counts lines, words, bytes" do
      bash = JustBash.new(files: %{"/file.txt" => "hello world\nfoo bar\n"})
      {result, _} = JustBash.exec(bash, "wc -l /file.txt")
      assert result.stdout == "2 /file.txt\n"
    end

    test "grep finds matching lines" do
      bash = JustBash.new(files: %{"/file.txt" => "hello world\nfoo bar\nhello again\n"})
      {result, _} = JustBash.exec(bash, "grep hello /file.txt")
      assert result.stdout == "hello world\nhello again\n"
    end

    test "printf formats output" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'Hello %s\\n' World")
      assert result.stdout == "Hello World\n"
    end

    test "basename extracts filename" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename /path/to/file.txt")
      assert result.stdout == "file.txt\n"
    end

    test "dirname extracts directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname /path/to/file.txt")
      assert result.stdout == "/path/to\n"
    end

    test "seq generates sequence" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 3")
      assert result.stdout == "1\n2\n3\n"

      {result2, _} = JustBash.exec(bash, "seq 2 4")
      assert result2.stdout == "2\n3\n4\n"
    end

    test "sort sorts lines" do
      bash = JustBash.new(files: %{"/file.txt" => "banana\napple\ncherry\n"})
      {result, _} = JustBash.exec(bash, "sort /file.txt")
      assert result.stdout == "apple\nbanana\ncherry\n"
    end

    test "uniq removes consecutive duplicates" do
      bash = JustBash.new(files: %{"/file.txt" => "a\na\nb\nb\na\n"})
      {result, _} = JustBash.exec(bash, "uniq /file.txt")
      assert result.stdout == "a\nb\na\n"
    end

    test "date outputs current date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/\d{4}/
    end

    test "exit sets exit code" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "exit 42")
      assert result.exit_code == 42
    end
  end

  describe "echo command extended" do
    test "echo with -E flag disables escapes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -E "hello\nworld"])
      assert result.stdout == "hello\\nworld\n"
    end

    test "echo with -ne combined flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -ne "hello\nworld"])
      assert result.stdout == "hello\nworld"
    end

    test "echo with -en combined flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -en "hello\tworld"])
      assert result.stdout == "hello\tworld"
    end

    test "echo with no args outputs newline" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo")
      assert result.stdout == "\n"
    end

    test "echo -e with tab and carriage return" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -e "a\tb\rc"])
      assert result.stdout == "a\tb\rc\n"
    end

    test "echo -e with escaped backslash" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -e "back\\\\slash"])
      assert result.stdout == "back\\slash\n"
    end
  end

  describe "cat command extended" do
    test "cat reads from stdin when no args" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | cat")
      assert result.stdout == "hello\n"
    end

    test "cat reports error for directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cat /home")
      assert result.exit_code == 1
      assert result.stderr =~ "Is a directory"
    end

    test "cat concatenates multiple files" do
      bash = JustBash.new(files: %{"/a.txt" => "aaa\n", "/b.txt" => "bbb\n"})
      {result, _} = JustBash.exec(bash, "cat /a.txt /b.txt")
      assert result.stdout == "aaa\nbbb\n"
    end
  end

  describe "ls command extended" do
    test "ls lists directory contents" do
      bash = JustBash.new(files: %{"/data/file1.txt" => "a", "/data/file2.txt" => "b"})
      {result, _} = JustBash.exec(bash, "ls /data")
      assert result.stdout =~ "file1.txt"
      assert result.stdout =~ "file2.txt"
    end

    test "ls -a shows hidden files and . .." do
      bash = JustBash.new(files: %{"/data/.hidden" => "x", "/data/visible" => "y"})
      {result, _} = JustBash.exec(bash, "ls -a /data")
      assert result.stdout =~ "."
      assert result.stdout =~ ".."
      assert result.stdout =~ ".hidden"
      assert result.stdout =~ "visible"
    end

    test "ls -l shows long format" do
      bash = JustBash.new(files: %{"/data/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "ls -l /data")
      assert result.stdout =~ "file.txt"
      assert result.stdout =~ "rw"
    end

    test "ls -la combines flags" do
      bash = JustBash.new(files: %{"/data/.hidden" => "x"})
      {result, _} = JustBash.exec(bash, "ls -la /data")
      assert result.stdout =~ ".hidden"
      assert result.stdout =~ "rw"
    end

    test "ls hides dotfiles by default" do
      bash = JustBash.new(files: %{"/data/.hidden" => "x", "/data/visible" => "y"})
      {result, _} = JustBash.exec(bash, "ls /data")
      refute result.stdout =~ ".hidden"
      assert result.stdout =~ "visible"
    end

    test "ls on single file shows filename" do
      bash = JustBash.new(files: %{"/file.txt" => "x"})
      {result, _} = JustBash.exec(bash, "ls /file.txt")
      assert result.stdout == "/file.txt\n"
    end
  end

  describe "cd command extended" do
    test "cd - returns to previous directory" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "cd /tmp")
      {result, bash} = JustBash.exec(bash, "cd -")
      assert result.stdout == "/home/user\n"
      assert bash.cwd == "/home/user"
    end

    test "cd to file fails" do
      bash = JustBash.new(files: %{"/file.txt" => "x"})
      {result, _} = JustBash.exec(bash, "cd /file.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "Not a directory"
    end
  end

  describe "mkdir command" do
    test "mkdir creates directory" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "mkdir /newdir")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -d /newdir ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "mkdir -p creates nested directories" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "mkdir -p /a/b/c/d")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -d /a/b/c/d ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "mkdir fails if parent doesn't exist" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "mkdir /nonexistent/dir")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "mkdir fails if already exists" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "mkdir /mydir")
      {result, _} = JustBash.exec(bash, "mkdir /mydir")
      assert result.exit_code == 1
      assert result.stderr =~ "File exists"
    end

    test "mkdir -p ignores existing directory" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "mkdir -p /mydir")
      {result, _} = JustBash.exec(bash, "mkdir -p /mydir")
      assert result.exit_code == 0
    end
  end

  describe "rm command extended" do
    test "rm -r removes directory recursively" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "x"})
      {result, bash} = JustBash.exec(bash, "rm -r /dir")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -d /dir ] || echo gone")
      assert result.stdout == "gone\n"
    end

    test "rm -rf removes without error on missing" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm -rf /nonexistent")
      assert result.exit_code == 0
    end

    test "rm -fr works same as -rf" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm -fr /nonexistent")
      assert result.exit_code == 0
    end

    test "rm on non-empty directory without -r fails" do
      bash = JustBash.new(files: %{"/mydir/file.txt" => "x"})
      {result, _} = JustBash.exec(bash, "rm /mydir")
      assert result.exit_code == 1
      assert result.stderr =~ "Directory not empty"
    end
  end

  describe "touch command extended" do
    test "touch creates new file" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "touch /newfile.txt")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -f /newfile.txt ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "touch multiple files" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "touch /a.txt /b.txt /c.txt")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "ls /")
      assert result.stdout =~ "a.txt"
      assert result.stdout =~ "b.txt"
      assert result.stdout =~ "c.txt"
    end
  end

  describe "cp command" do
    test "cp file not found error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cp /nonexistent /dest")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "cp missing operand error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cp")
      assert result.exit_code == 1
      assert result.stderr =~ "missing file operand"
    end
  end

  describe "mv command" do
    test "mv file not found error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "mv /nonexistent /dest")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "mv missing operand error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "mv")
      assert result.exit_code == 1
      assert result.stderr =~ "missing file operand"
    end

    test "mv removes source file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {_, bash} = JustBash.exec(bash, "mv /src.txt /dst.txt")
      {result, _} = JustBash.exec(bash, "[ -f /src.txt ] || echo gone")
      assert result.stdout == "gone\n"
    end
  end

  describe "head command" do
    test "head defaults to 10 lines" do
      lines = Enum.map_join(1..15, "\n", &to_string/1) <> "\n"
      bash = JustBash.new(files: %{"/nums.txt" => lines})
      {result, _} = JustBash.exec(bash, "head /nums.txt")
      assert result.stdout == Enum.map_join(1..10, "\n", &to_string/1) <> "\n"
    end

    test "head -5 shows 5 lines" do
      lines = Enum.map_join(1..10, "\n", &to_string/1) <> "\n"
      bash = JustBash.new(files: %{"/nums.txt" => lines})
      {result, _} = JustBash.exec(bash, "head -5 /nums.txt")
      assert result.stdout == Enum.map_join(1..5, "\n", &to_string/1) <> "\n"
    end

    test "head reads from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 20 | head -3")
      assert result.stdout == "1\n2\n3\n"
    end

    test "head file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "head /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "head on empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "head /empty.txt")
      assert result.exit_code == 0
    end
  end

  describe "tail command" do
    test "tail defaults to 10 lines" do
      lines = Enum.map_join(1..15, "\n", &to_string/1) <> "\n"
      bash = JustBash.new(files: %{"/nums.txt" => lines})
      {result, _} = JustBash.exec(bash, "tail /nums.txt")
      assert result.stdout == Enum.map_join(6..15, "\n", &to_string/1) <> "\n"
    end

    test "tail -3 shows last 3 lines" do
      lines = Enum.map_join(1..10, "\n", &to_string/1) <> "\n"
      bash = JustBash.new(files: %{"/nums.txt" => lines})
      {result, _} = JustBash.exec(bash, "tail -3 /nums.txt")
      assert result.stdout == "8\n9\n10\n"
    end

    test "tail reads from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 10 | tail -2")
      assert result.stdout == "9\n10\n"
    end

    test "tail file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "tail /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end
  end

  describe "wc command" do
    test "wc -w counts words" do
      bash = JustBash.new(files: %{"/text.txt" => "one two three\nfour five\n"})
      {result, _} = JustBash.exec(bash, "wc -w /text.txt")
      assert result.stdout =~ "5"
    end

    test "wc -c counts bytes" do
      bash = JustBash.new(files: %{"/text.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "wc -c /text.txt")
      assert result.stdout =~ "5"
    end

    test "wc with no flags shows all counts" do
      bash = JustBash.new(files: %{"/text.txt" => "one two\nthree\n"})
      {result, _} = JustBash.exec(bash, "wc /text.txt")
      # lines
      assert result.stdout =~ "2"
      # words
      assert result.stdout =~ "3"
    end

    test "wc reads from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'a b c' | wc -w")
      assert String.trim(result.stdout) == "3"
    end

    test "wc file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "wc /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end
  end

  describe "grep command" do
    test "grep -i case insensitive" do
      bash = JustBash.new(files: %{"/text.txt" => "Hello\nWORLD\nhello\n"})
      {result, _} = JustBash.exec(bash, "grep -i hello /text.txt")
      assert result.stdout == "Hello\nhello\n"
    end

    test "grep -v inverts match" do
      bash = JustBash.new(files: %{"/text.txt" => "apple\nbanana\ncherry"})
      {result, _} = JustBash.exec(bash, "grep -v a /text.txt")
      assert result.stdout == "cherry\n"
    end

    test "grep multiple files shows prefix" do
      bash = JustBash.new(files: %{"/a.txt" => "hello\n", "/b.txt" => "hello\nworld\n"})
      {result, _} = JustBash.exec(bash, "grep hello /a.txt /b.txt")
      assert result.stdout =~ "/a.txt:hello"
      assert result.stdout =~ "/b.txt:hello"
    end

    test "grep no match returns exit 1" do
      bash = JustBash.new(files: %{"/text.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "grep notfound /text.txt")
      assert result.exit_code == 1
      assert result.stdout == ""
    end

    test "grep missing pattern" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "grep")
      assert result.exit_code == 2
      assert result.stderr =~ "missing pattern"
    end

    test "grep from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'apple\\nbanana\\napricot' | grep ap")
      assert result.stdout == "apple\napricot\n"
    end
  end

  describe "sort command" do
    test "sort -r reverses" do
      bash = JustBash.new(files: %{"/nums.txt" => "a\nc\nb\n"})
      {result, _} = JustBash.exec(bash, "sort -r /nums.txt")
      assert result.stdout == "c\nb\na\n"
    end

    test "sort -u removes duplicates" do
      bash = JustBash.new(files: %{"/nums.txt" => "a\nb\na\nc\nb\n"})
      {result, _} = JustBash.exec(bash, "sort -u /nums.txt")
      assert result.stdout == "a\nb\nc\n"
    end

    test "sort -n numeric" do
      bash = JustBash.new(files: %{"/nums.txt" => "10\n2\n1\n20\n"})
      {result, _} = JustBash.exec(bash, "sort -n /nums.txt")
      assert result.stdout == "1\n2\n10\n20\n"
    end

    test "sort -rn combined" do
      bash = JustBash.new(files: %{"/nums.txt" => "10\n2\n1\n"})
      {result, _} = JustBash.exec(bash, "sort -rn /nums.txt")
      assert result.stdout == "10\n2\n1\n"
    end

    test "sort from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'c\\na\\nb' | sort")
      assert result.stdout == "a\nb\nc\n"
    end
  end

  describe "uniq command" do
    test "uniq -c counts occurrences" do
      bash = JustBash.new(files: %{"/data.txt" => "a\na\nb\na\n"})
      {result, _} = JustBash.exec(bash, "uniq -c /data.txt")
      assert result.stdout =~ "2 a"
      assert result.stdout =~ "1 b"
    end

    test "uniq from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'a\\na\\nb' | uniq")
      assert result.stdout == "a\nb\n"
    end
  end

  describe "tr command" do
    test "tr translates characters" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | tr 'el' 'ip'")
      assert result.stdout == "hippo\n"
    end

    test "tr with character ranges" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | tr 'a-z' 'A-Z'")
      assert result.stdout == "HELLO\n"
    end

    test "tr -d deletes characters" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | tr -d 'l'")
      assert result.stdout == "heo\n"
    end

    test "tr missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | tr")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end
  end

  describe "seq command" do
    test "seq with 3 args (start incr end)" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 1 2 7")
      assert result.stdout == "1\n3\n5\n7\n"
    end

    test "seq invalid argument" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq abc")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid argument"
    end

    test "seq missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end

    test "seq negative step" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 5 -1 1")
      assert result.stdout == "5\n4\n3\n2\n1\n"
    end
  end

  describe "read command" do
    test "read stores in variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | read x; echo $x")
      assert result.stdout == "hello\n"
    end

    test "read defaults to REPLY" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo world | read; echo $REPLY")
      assert result.stdout == "world\n"
    end

    test "read with empty stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | read x; echo \"got:$x:\"")
      assert result.stdout == "got::\n"
    end
  end

  describe "test command extras" do
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
  end

  describe "printf command" do
    test "printf with %d format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'num: %d' 42")
      assert result.stdout == "num: 42"
    end

    test "printf with multiple args" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%s=%s' key value")
      assert result.stdout == "key=value"
    end

    test "printf missing args uses defaults" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a:%s:b:%d:'")
      assert result.stdout == "a::b:0:"
    end

    test "printf with tab escape" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[printf "a\tb"])
      assert result.stdout == "a\tb"
    end
  end

  describe "basename command" do
    test "basename with suffix removal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename /path/to/file.txt .txt")
      assert result.stdout == "file\n"
    end

    test "basename missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end
  end

  describe "dirname command" do
    test "dirname missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end

    test "dirname with nested path" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname /a/b/c/d.txt")
      assert result.stdout == "/a/b/c\n"
    end
  end

  describe "date command" do
    test "date outputs formatted time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date")
      assert result.exit_code == 0
      # has year
      assert result.stdout =~ ~r/\d{4}/
      assert result.stdout =~ "UTC"
    end
  end

  describe "sleep command" do
    test "sleep accepts argument" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "sleep 1")
      assert result.exit_code == 0
    end
  end

  describe "exit command extras" do
    test "exit with no arg defaults to 0" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "exit")
      assert result.exit_code == 0
    end

    test "exit with invalid arg defaults to 1" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "exit abc")
      assert result.exit_code == 1
    end
  end

  describe "export command" do
    test "export without value inherits existing" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "FOO=bar")
      {result, _} = JustBash.exec(bash, "export FOO; echo $FOO")
      assert result.stdout == "bar\n"
    end

    test "export multiple variables" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "export A=1 B=2; echo $A$B")
      assert result.stdout == "12\n"
    end
  end

  describe "unset command" do
    test "unset multiple variables" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "A=1; B=2; C=3")
      {result, _} = JustBash.exec(bash, "unset A B; echo \"$A$B$C\"")
      assert result.stdout == "3\n"
    end

    test "unset nonexistent variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "unset NONEXISTENT")
      assert result.exit_code == 0
    end
  end
end
