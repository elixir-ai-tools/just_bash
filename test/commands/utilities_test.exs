defmodule JustBash.Commands.UtilitiesTest do
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

  describe "printf command" do
    test "printf formats output" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'Hello %s\\n' World")
      assert result.stdout == "Hello World\n"
    end

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

    test "printf with %x hex format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%x' 255")
      assert result.stdout == "ff"
    end

    test "printf with %X uppercase hex format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%X' 255")
      assert result.stdout == "FF"
    end

    test "printf with %o octal format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%o' 64")
      assert result.stdout == "100"
    end

    test "printf with %f float format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%f' 3.14159")
      assert result.stdout == "3.141590"
    end

    test "printf with %f precision" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%.2f' 3.14159")
      assert result.stdout == "3.14"
    end

    test "printf with width specifier" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%10s' hello")
      assert result.stdout == "     hello"
    end

    test "printf with left-align" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%-10s' hello")
      assert result.stdout == "hello     "
    end

    test "printf with %c character format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%c' abc")
      assert result.stdout == "a"
    end

    test "printf with %% literal percent" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '100%%'")
      assert result.stdout == "100%"
    end

    test "printf with %e scientific notation" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%e' 12345")
      assert result.stdout =~ ~r/1\.\d+e\+0?4/i
    end
  end

  describe "date command" do
    test "date outputs current date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/\d{4}/
    end

    test "date outputs formatted time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/\d{4}/
      assert result.stdout =~ "UTC"
    end

    test "date with custom format +%Y-%m-%d" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date '+%Y-%m-%d'")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/^\d{4}-\d{2}-\d{2}\n$/
    end

    test "date with -d for specific date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-01-15' '+%Y-%m-%d'")
      assert result.exit_code == 0
      assert result.stdout == "2024-01-15\n"
    end

    test "date with unix timestamp format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-01-01' '+%s'")
      assert result.exit_code == 0
      assert result.stdout == "1704067200\n"
    end

    test "date with weekday format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-01-15' '+%A'")
      assert result.exit_code == 0
      assert result.stdout == "Monday\n"
    end

    test "date with month format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-03-01' '+%B'")
      assert result.exit_code == 0
      assert result.stdout == "March\n"
    end

    test "date with invalid date returns error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d 'not-a-date'")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid date"
    end
  end

  describe "seq command" do
    test "seq generates sequence" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 3")
      assert result.stdout == "1\n2\n3\n"

      {result2, _} = JustBash.exec(bash, "seq 2 4")
      assert result2.stdout == "2\n3\n4\n"
    end

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

  describe "basename command" do
    test "basename extracts filename" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename /path/to/file.txt")
      assert result.stdout == "file.txt\n"
    end

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
    test "dirname extracts directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname /path/to/file.txt")
      assert result.stdout == "/path/to\n"
    end

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

  describe "env command" do
    test "env prints all environment variables" do
      bash = JustBash.new(env: %{"FOO" => "bar", "BAZ" => "qux"})
      {result, _} = JustBash.exec(bash, "env")
      assert result.stdout =~ "FOO=bar"
      assert result.stdout =~ "BAZ=qux"
      assert result.exit_code == 0
    end

    test "env includes default environment variables" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "env")
      assert result.stdout =~ "HOME=/home/user"
      assert result.stdout =~ "PATH=/bin:/usr/bin"
    end

    test "env with -i starts with empty environment" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, _} = JustBash.exec(bash, "env -i")
      assert result.stdout == ""
    end

    test "env command receives FOO=bar as argument" do
      bash = JustBash.new()
      {result, _} = JustBash.Commands.Env.execute(bash, ["FOO=bar"], "")
      assert result.stdout =~ "FOO=bar"
    end

    test "env command with -i and NAME=VALUE as argument" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, _} = JustBash.Commands.Env.execute(bash, ["-i", "BAZ=qux"], "")
      assert result.stdout == "BAZ=qux\n"
      refute result.stdout =~ "FOO"
    end
  end

  describe "printenv command" do
    test "printenv prints all environment variables without args" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, _} = JustBash.exec(bash, "printenv")
      assert result.stdout =~ "FOO=bar"
      assert result.exit_code == 0
    end

    test "printenv prints specific variable value" do
      bash = JustBash.new(env: %{"FOO" => "bar", "BAZ" => "qux"})
      {result, _} = JustBash.exec(bash, "printenv FOO")
      assert result.stdout == "bar\n"
      assert result.exit_code == 0
    end

    test "printenv prints multiple variable values" do
      bash = JustBash.new(env: %{"FOO" => "bar", "BAZ" => "qux"})
      {result, _} = JustBash.exec(bash, "printenv FOO BAZ")
      assert result.stdout == "bar\nqux\n"
    end

    test "printenv returns exit code 1 for missing variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printenv NONEXISTENT")
      assert result.exit_code == 1
    end
  end

  describe "which command" do
    test "which finds command in PATH" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which ls")
      assert result.stdout == "/bin/ls\n"
      assert result.exit_code == 0
    end

    test "which finds multiple commands" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which ls cat echo")
      assert result.stdout == "/bin/ls\n/bin/cat\n/bin/echo\n"
      assert result.exit_code == 0
    end

    test "which returns exit 1 for nonexistent command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which nonexistent")
      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "which returns exit 1 if any command not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which ls nonexistent cat")
      assert result.stdout == "/bin/ls\n/bin/cat\n"
      assert result.exit_code == 1
    end

    test "which with -s for silent mode" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -s ls")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "which returns exit 1 with -s for nonexistent" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -s nonexistent")
      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "which with -a to show all matches" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -a ls")
      assert result.stdout =~ "/bin/ls"
      assert result.exit_code == 0
    end

    test "which returns exit 1 with no arguments" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which")
      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "which supports combined -as flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -as ls")
      assert result.stdout == ""
      assert result.exit_code == 0
    end
  end

  describe "hostname command" do
    test "hostname returns localhost" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "hostname")
      assert result.stdout == "localhost\n"
      assert result.exit_code == 0
    end
  end

  describe "tee command" do
    test "tee passes through stdin to stdout" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | tee")
      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end

    test "tee writes to file and stdout" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "echo hello | tee /home/user/output.txt")
      assert result.stdout == "hello\n"
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /home/user/output.txt")
      assert cat_result.stdout == "hello\n"
    end

    test "tee writes to multiple files" do
      bash = JustBash.new()

      {result, new_bash} =
        JustBash.exec(bash, "echo hello | tee /home/user/file1.txt /home/user/file2.txt")

      assert result.stdout == "hello\n"

      {cat1, _} = JustBash.exec(new_bash, "cat /home/user/file1.txt")
      {cat2, _} = JustBash.exec(new_bash, "cat /home/user/file2.txt")
      assert cat1.stdout == "hello\n"
      assert cat2.stdout == "hello\n"
    end

    test "tee with -a appends to file" do
      bash = JustBash.new(files: %{"/test.txt" => "existing\n"})
      {result, new_bash} = JustBash.exec(bash, "echo appended | tee -a /test.txt")
      assert result.stdout == "appended\n"

      {cat_result, _} = JustBash.exec(new_bash, "cat /test.txt")
      assert cat_result.stdout == "existing\nappended\n"
    end

    test "tee with --append flag appends to file" do
      bash = JustBash.new(files: %{"/test.txt" => "existing\n"})
      {result, new_bash} = JustBash.exec(bash, "echo appended | tee --append /test.txt")
      assert result.stdout == "appended\n"

      {cat_result, _} = JustBash.exec(new_bash, "cat /test.txt")
      assert cat_result.stdout == "existing\nappended\n"
    end

    test "tee creates file if it doesn't exist" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "echo new | tee /home/user/new.txt")
      assert result.stdout == "new\n"
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /home/user/new.txt")
      assert cat_result.stdout == "new\n"
    end

    test "tee fails if parent directory doesn't exist" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo test | tee /nonexistent/file.txt")
      assert result.stderr =~ "No such file or directory"
      assert result.exit_code == 1
      assert result.stdout == "test\n"
    end

    test "tee with empty stdin" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "echo -n '' | tee /home/user/empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /home/user/empty.txt")
      assert cat_result.stdout == ""
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

  describe "sleep command" do
    test "sleep accepts argument" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "sleep 1")
      assert result.exit_code == 0
    end
  end

  describe "exit command" do
    test "exit sets exit code" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "exit 42")
      assert result.exit_code == 42
    end

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

  describe "xargs command" do
    test "xargs executes echo by default" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | xargs")
      assert result.stdout == "a b c\n"
      assert result.exit_code == 0
    end

    test "xargs executes specified command" do
      bash = JustBash.new(files: %{"/file1.txt" => "content1", "/file2.txt" => "content2"})
      {result, _} = JustBash.exec(bash, "echo '/file1.txt /file2.txt' | xargs cat")
      assert result.stdout == "content1content2"
    end

    test "xargs handles empty input" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | xargs")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "xargs with -n 1 batches one at a time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | xargs -n 1 echo")
      assert result.stdout == "a\nb\nc\n"
    end

    test "xargs with -n 2 batches two at a time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c d' | xargs -n 2 echo")
      assert result.stdout == "a b\nc d\n"
    end

    test "xargs with -n handles partial last batch" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | xargs -n 2 echo")
      assert result.stdout == "a b\nc\n"
    end

    test "xargs with -I replaces placeholder" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'a\\nb\\nc' | xargs -I % echo file-%")
      assert result.stdout == "file-a\nfile-b\nfile-c\n"
    end

    test "xargs with -I replaces multiple occurrences" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'x' | xargs -I % echo %-%")
      assert result.stdout == "x-x\n"
    end

    test "xargs with -t verbose mode prints commands" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'x y' | xargs -t echo")
      assert result.stdout == "x y\n"
      assert result.stderr == "echo x y\n"
    end

    test "xargs with -r does not run when empty" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | xargs -r echo nonempty")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "xargs propagates command failure exit code" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'missing.txt' | xargs cat")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "xargs with --help shows help" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "xargs --help")
      assert result.stdout =~ "xargs"
      assert result.stdout =~ "-I"
      assert result.stdout =~ "-n"
      assert result.exit_code == 0
    end

    test "xargs with file operations" do
      bash = JustBash.new(files: %{"/src/a.txt" => "content-a", "/src/b.txt" => "content-b"})
      {result, _} = JustBash.exec(bash, "echo -e '/src/a.txt\\n/src/b.txt' | xargs -I % cat %")
      assert result.stdout == "content-acontent-b"
    end

    test "xargs handles find | xargs rm pattern" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/file1.tmp" => "temp1",
            "/tmp/file2.tmp" => "temp2",
            "/keep/file.txt" => "keep"
          }
        )

      {_, bash} = JustBash.exec(bash, "echo '/tmp/file1.tmp /tmp/file2.tmp' | xargs rm")
      {result, _} = JustBash.exec(bash, "cat /tmp/file1.tmp")
      assert result.exit_code == 1

      {result, _} = JustBash.exec(bash, "cat /keep/file.txt")
      assert result.stdout == "keep"
    end
  end
end
