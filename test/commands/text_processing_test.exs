defmodule JustBash.Commands.TextProcessingTest do
  use ExUnit.Case, async: true

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

  describe "head command" do
    test "head shows first lines" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\nline3\nline4\nline5\n"})
      {result, _} = JustBash.exec(bash, "head -n 2 /file.txt")
      assert result.stdout == "line1\nline2\n"
    end

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
    test "tail shows last lines" do
      bash = JustBash.new(files: %{"/file.txt" => "line1\nline2\nline3\nline4\nline5\n"})
      {result, _} = JustBash.exec(bash, "tail -n 2 /file.txt")
      assert result.stdout == "line4\nline5\n"
    end

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

  describe "grep command" do
    test "grep finds matching lines" do
      bash = JustBash.new(files: %{"/file.txt" => "hello world\nfoo bar\nhello again\n"})
      {result, _} = JustBash.exec(bash, "grep hello /file.txt")
      assert result.stdout == "hello world\nhello again\n"
    end

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

  describe "sed command" do
    test "sed replaces first occurrence per line" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world\nhello universe\n"})
      {result, _} = JustBash.exec(bash, "sed 's/hello/hi/' /test.txt")
      assert result.stdout == "hi world\nhi universe\n"
      assert result.exit_code == 0
    end

    test "sed replaces all occurrences with g flag" do
      bash = JustBash.new(files: %{"/test.txt" => "hello hello hello\n"})
      {result, _} = JustBash.exec(bash, "sed 's/hello/hi/g' /test.txt")
      assert result.stdout == "hi hi hi\n"
    end

    test "sed reads from stdin via pipe" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'foo bar' | sed 's/bar/baz/'")
      assert result.stdout == "foo baz\n"
    end

    test "sed uses different delimiter" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '/path/to/file' | sed 's#/path#/newpath#'")
      assert result.stdout == "/newpath/to/file\n"
    end

    test "sed handles empty replacement" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello world' | sed 's/world//'")
      assert result.stdout == "hello \n"
    end

    test "sed with -n suppresses output" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\n"})
      {result, _} = JustBash.exec(bash, "sed -n '2p' /test.txt")
      assert result.stdout == "line 2\n"
    end

    test "sed deletes matching lines" do
      bash =
        JustBash.new(files: %{"/test.txt" => "hello world\nhello universe\ngoodbye world\n"})

      {result, _} = JustBash.exec(bash, "sed '/hello/d' /test.txt")
      assert result.stdout == "goodbye world\n"
    end

    test "sed deletes specific line number" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\n"})
      {result, _} = JustBash.exec(bash, "sed '2d' /test.txt")
      assert result.stdout == "line 1\nline 3\n"
    end

    test "sed deletes range of lines" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\nline 4\nline 5\n"})
      {result, _} = JustBash.exec(bash, "sed '2,4d' /test.txt")
      assert result.stdout == "line 1\nline 5\n"
    end

    test "sed prints range of lines with -n" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\nline 4\nline 5\n"})
      {result, _} = JustBash.exec(bash, "sed -n '2,4p' /test.txt")
      assert result.stdout == "line 2\nline 3\nline 4\n"
    end

    test "sed substitutes only on specific line" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\n"})
      {result, _} = JustBash.exec(bash, "sed '2s/line/LINE/' /test.txt")
      assert result.stdout == "line 1\nLINE 2\nline 3\n"
    end

    test "sed substitutes on range of lines" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\nline 4\nline 5\n"})
      {result, _} = JustBash.exec(bash, "sed '2,4s/line/LINE/' /test.txt")
      assert result.stdout == "line 1\nLINE 2\nLINE 3\nLINE 4\nline 5\n"
    end

    test "sed case insensitive with i flag" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'HELLO world' | sed 's/hello/hi/i'")
      assert result.stdout == "hi world\n"
    end

    test "sed combines i and g flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'Hello HELLO hello' | sed 's/hello/hi/gi'")
      assert result.stdout == "hi hi hi\n"
    end

    test "sed handles regex patterns" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\n"})
      {result, _} = JustBash.exec(bash, "sed 's/[0-9]/X/' /test.txt")
      assert result.stdout == "line X\nline X\nline X\n"
    end

    test "sed deletes last line with $" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\n"})
      {result, _} = JustBash.exec(bash, "sed '$d' /test.txt")
      assert result.stdout == "line 1\nline 2\n"
    end

    test "sed substitutes on last line with $" do
      bash = JustBash.new(files: %{"/test.txt" => "line 1\nline 2\nline 3\n"})
      {result, _} = JustBash.exec(bash, "sed '$ s/line/LINE/' /test.txt")
      assert result.stdout == "line 1\nline 2\nLINE 3\n"
    end

    test "sed multiple expressions with -e" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, "sed -e 's/hello/hi/' -e 's/world/there/' /test.txt")
      assert result.stdout == "hi there\n"
    end

    test "sed errors on non-existent file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "sed 's/a/b/' /nonexistent.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "sed in-place editing with -i" do
      bash = JustBash.new(files: %{"/test.txt" => "hello world\n"})
      {_, new_bash} = JustBash.exec(bash, "sed -i 's/hello/hi/' /test.txt")
      {result, _} = JustBash.exec(new_bash, "cat /test.txt")
      assert result.stdout == "hi world\n"
    end

    test "sed shows help with --help" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "sed --help")
      assert result.stdout =~ "sed"
      assert result.stdout =~ "substitute"
      assert result.exit_code == 0
    end

    test "sed regex range /start/,/end/ prints all lines in range" do
      bash =
        JustBash.new(files: %{"/test.txt" => "line1\nSTART\nmiddle1\nmiddle2\nEND\nline2\n"})

      {result, _} = JustBash.exec(bash, "sed -n '/START/,/END/p' /test.txt")
      assert result.stdout == "START\nmiddle1\nmiddle2\nEND\n"
      assert result.exit_code == 0
    end

    test "sed regex range deletes all lines in range" do
      bash =
        JustBash.new(files: %{"/test.txt" => "keep1\nSTART\ndelete1\ndelete2\nEND\nkeep2\n"})

      {result, _} = JustBash.exec(bash, "sed '/START/,/END/d' /test.txt")
      assert result.stdout == "keep1\nkeep2\n"
      assert result.exit_code == 0
    end

    test "sed regex range substitutes on all lines in range" do
      bash =
        JustBash.new(files: %{"/test.txt" => "line1\nSTART\nfoo\nbar\nEND\nline2\n"})

      {result, _} = JustBash.exec(bash, "sed '/START/,/END/s/^/>> /' /test.txt")
      assert result.stdout == "line1\n>> START\n>> foo\n>> bar\n>> END\nline2\n"
      assert result.exit_code == 0
    end

    test "sed regex range with multiple ranges in file" do
      bash =
        JustBash.new(
          files: %{
            "/test.txt" => "a\nBEGIN\nb\nEND\nc\nBEGIN\nd\nEND\ne\n"
          }
        )

      {result, _} = JustBash.exec(bash, "sed -n '/BEGIN/,/END/p' /test.txt")
      assert result.stdout == "BEGIN\nb\nEND\nBEGIN\nd\nEND\n"
      assert result.exit_code == 0
    end

    test "sed regex range where end pattern never matches" do
      bash =
        JustBash.new(files: %{"/test.txt" => "line1\nSTART\nline2\nline3\n"})

      # When end pattern never matches, range continues to end of file
      {result, _} = JustBash.exec(bash, "sed -n '/START/,/END/p' /test.txt")
      assert result.stdout == "START\nline2\nline3\n"
      assert result.exit_code == 0
    end
  end

  describe "awk command" do
    test "awk prints entire line with $0" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\nfoo bar\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $0}' /data.txt")
      assert result.stdout == "hello world\nfoo bar\n"
      assert result.exit_code == 0
    end

    test "awk prints first field with $1" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\nfoo bar\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1}' /data.txt")
      assert result.stdout == "hello\nfoo\n"
    end

    test "awk prints multiple fields" do
      bash = JustBash.new(files: %{"/data.txt" => "a b c\n1 2 3\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1, $3}' /data.txt")
      assert result.stdout == "a c\n1 3\n"
    end

    test "awk handles missing fields gracefully" do
      bash = JustBash.new(files: %{"/data.txt" => "one\ntwo three\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $2}' /data.txt")
      assert result.stdout == "\nthree\n"
    end

    test "awk uses custom field separator with -F" do
      bash = JustBash.new(files: %{"/data.csv" => "a,b,c\n1,2,3\n"})
      {result, _} = JustBash.exec(bash, "awk -F',' '{print $2}' /data.csv")
      assert result.stdout == "b\n2\n"
    end

    test "awk tracks NR record number" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\nc\n"})
      {result, _} = JustBash.exec(bash, "awk '{print NR, $0}' /data.txt")
      assert result.stdout == "1 a\n2 b\n3 c\n"
    end

    test "awk tracks NF number of fields" do
      bash = JustBash.new(files: %{"/data.txt" => "one\ntwo three\na b c d\n"})
      {result, _} = JustBash.exec(bash, "awk '{print NF}' /data.txt")
      assert result.stdout == "1\n2\n4\n"
    end

    test "awk executes BEGIN block" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print \"start\"}{print $0}' /data.txt")
      assert result.stdout == "start\na\nb\n"
    end

    test "awk executes END block" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $0}END{print \"done\"}' /data.txt")
      assert result.stdout == "a\nb\ndone\n"
    end

    test "awk filters with regex pattern" do
      bash = JustBash.new(files: %{"/data.txt" => "apple\nbanana\napricot\ncherry\n"})
      {result, _} = JustBash.exec(bash, "awk '/^a/{print}' /data.txt")
      assert result.stdout == "apple\napricot\n"
    end

    test "awk matches with NR condition" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "awk 'NR==2{print}' /data.txt")
      assert result.stdout == "line2\n"
    end

    test "awk matches with NR > condition" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "awk 'NR>1{print}' /data.txt")
      assert result.stdout == "line2\nline3\n"
    end

    test "awk reads from piped stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | awk '{print $2}'")
      assert result.stdout == "b\n"
    end

    test "awk uses -v assigned variable" do
      bash = JustBash.new(files: %{"/data.txt" => "test\n"})
      {result, _} = JustBash.exec(bash, "awk -vname=World '{print name}' /data.txt")
      assert result.stdout == "World\n"
    end

    test "awk errors on missing program" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "awk")
      assert result.exit_code == 1
      assert result.stderr =~ "missing program"
    end

    test "awk errors on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "awk '{print}' /nonexistent.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "awk shows help with --help" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "awk --help")
      assert result.stdout =~ "awk"
      assert result.stdout =~ "pattern"
      assert result.exit_code == 0
    end
  end

  describe "cut command" do
    test "cut first field with colon delimiter" do
      bash =
        JustBash.new(
          files: %{
            "/test/passwd.txt" =>
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:User:/home/user:/bin/zsh\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -d: -f1 /test/passwd.txt")
      assert result.stdout == "root\nuser\n"
      assert result.exit_code == 0
    end

    test "cut multiple fields" do
      bash =
        JustBash.new(
          files: %{
            "/test/passwd.txt" =>
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:User:/home/user:/bin/zsh\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -d: -f1,3 /test/passwd.txt")
      assert result.stdout == "root:0\nuser:1000\n"
      assert result.exit_code == 0
    end

    test "cut range of fields" do
      bash =
        JustBash.new(
          files: %{
            "/test/passwd.txt" =>
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:User:/home/user:/bin/zsh\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -d: -f1-3 /test/passwd.txt")
      assert result.stdout == "root:x:0\nuser:x:1000\n"
      assert result.exit_code == 0
    end

    test "cut with comma delimiter for CSV" do
      bash =
        JustBash.new(
          files: %{
            "/test/csv.txt" => "name,age,city\nJohn,25,NYC\nJane,30,LA\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -d, -f1,2 /test/csv.txt")
      assert result.stdout == "name,age\nJohn,25\nJane,30\n"
      assert result.exit_code == 0
    end

    test "cut uses tab as default delimiter" do
      bash =
        JustBash.new(
          files: %{
            "/test/tabs.txt" => "col1\tcol2\tcol3\nval1\tval2\tval3\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -f2 /test/tabs.txt")
      assert result.stdout == "col2\nval2\n"
      assert result.exit_code == 0
    end

    test "cut characters with -c" do
      bash =
        JustBash.new(
          files: %{
            "/test/text.txt" => "hello world\nabcdefghij\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -c1-5 /test/text.txt")
      assert result.stdout == "hello\nabcde\n"
      assert result.exit_code == 0
    end

    test "cut specific characters" do
      bash =
        JustBash.new(
          files: %{
            "/test/text.txt" => "hello world\nabcdefghij\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -c1,3,5 /test/text.txt")
      assert result.stdout == "hlo\nace\n"
      assert result.exit_code == 0
    end

    test "cut reads from stdin via pipe" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a:b:c' | cut -d: -f2")
      assert result.stdout == "b\n"
      assert result.exit_code == 0
    end

    test "cut field range from end with open range" do
      bash =
        JustBash.new(
          files: %{
            "/test/passwd.txt" =>
              "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:User:/home/user:/bin/zsh\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -d: -f5- /test/passwd.txt")
      assert result.stdout == "root:/root:/bin/bash\nUser:/home/user:/bin/zsh\n"
      assert result.exit_code == 0
    end

    test "cut returns error when no field or char specified" do
      bash = JustBash.new(files: %{"/test/text.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "cut /test/text.txt")
      assert result.stderr == "cut: you must specify a list of bytes, characters, or fields\n"
      assert result.exit_code == 1
    end

    test "cut with -s suppresses lines without delimiter" do
      bash =
        JustBash.new(
          files: %{
            "/test/mixed.txt" => "a:b:c\nno delimiter here\nx:y:z\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cut -d: -f1 -s /test/mixed.txt")
      assert result.stdout == "a\nx\n"
      assert result.exit_code == 0
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

  describe "sort command" do
    test "sort sorts lines" do
      bash = JustBash.new(files: %{"/file.txt" => "banana\napple\ncherry\n"})
      {result, _} = JustBash.exec(bash, "sort /file.txt")
      assert result.stdout == "apple\nbanana\ncherry\n"
    end

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
    test "uniq removes consecutive duplicates" do
      bash = JustBash.new(files: %{"/file.txt" => "a\na\nb\nb\na\n"})
      {result, _} = JustBash.exec(bash, "uniq /file.txt")
      assert result.stdout == "a\nb\na\n"
    end

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

  describe "wc command" do
    test "wc counts lines, words, bytes" do
      bash = JustBash.new(files: %{"/file.txt" => "hello world\nfoo bar\n"})
      {result, _} = JustBash.exec(bash, "wc -l /file.txt")
      assert result.stdout == "       2 /file.txt\n"
    end

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
      assert result.stdout =~ "2"
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

  describe "tac command" do
    test "tac reverses lines from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'a\\nb\\nc' | tac")
      assert result.stdout == "c\nb\na\n"
    end

    test "tac reverses lines from file" do
      bash = JustBash.new(files: %{"/test.txt" => "first\nsecond\nthird\n"})
      {result, _} = JustBash.exec(bash, "tac /test.txt")
      assert result.stdout == "third\nsecond\nfirst\n"
    end

    test "tac handles single line" do
      bash = JustBash.new(files: %{"/test.txt" => "only line\n"})
      {result, _} = JustBash.exec(bash, "tac /test.txt")
      assert result.stdout == "only line\n"
    end

    test "tac handles empty input" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n '' | tac")
      assert result.stdout == ""
    end

    test "tac errors on nonexistent file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "tac /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "rev command" do
    test "rev reverses characters in each line from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | rev")
      assert result.stdout == "olleh\n"
    end

    test "rev reverses multiple lines" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'hello\\nworld' | rev")
      assert result.stdout == "olleh\ndlrow\n"
    end

    test "rev from file" do
      bash = JustBash.new(files: %{"/test.txt" => "abc\n123\n"})
      {result, _} = JustBash.exec(bash, "rev /test.txt")
      assert result.stdout == "cba\n321\n"
    end

    test "rev handles empty lines" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'a\\n\\nb' | rev")
      assert result.stdout == "a\n\nb\n"
    end

    test "rev errors on nonexistent file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rev /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "nl command" do
    test "nl numbers lines from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\nb\\nc' | nl")
      assert result.stdout == "     1\ta\n     2\tb\n     3\tc"
    end

    test "nl numbers lines from file" do
      bash = JustBash.new(files: %{"/test.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "nl /test.txt")
      assert result.stdout == "     1\tline1\n     2\tline2\n     3\tline3\n"
    end

    test "nl skips empty lines with default style" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\n\\nb\\n' | nl")
      assert result.stdout == "     1\ta\n      \t\n     2\tb\n"
    end

    test "nl numbers all lines with -ba" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\n\\nb\\n' | nl -ba")
      assert result.stdout == "     1\ta\n     2\t\n     3\tb\n"
    end

    test "nl with -n rz uses zeros" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\nb\\n' | nl -n rz")
      assert result.stdout == "000001\ta\n000002\tb\n"
    end

    test "nl with -w sets width" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\nb\\n' | nl -w 3")
      assert result.stdout == "  1\ta\n  2\tb\n"
    end

    test "nl with -s sets separator" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\nb\\n' | nl -s ': '")
      assert result.stdout == "     1: a\n     2: b\n"
    end

    test "nl with -v sets starting number" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\nb\\n' | nl -v 10")
      assert result.stdout == "    10\ta\n    11\tb\n"
    end

    test "nl with -i sets increment" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\nb\\nc\\n' | nl -i 5")
      assert result.stdout == "     1\ta\n     6\tb\n    11\tc\n"
    end

    test "nl handles file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "nl /nonexistent.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "fold command" do
    test "fold wraps long lines at default width 80" do
      bash = JustBash.new()
      long_line = String.duplicate("a", 100)
      {result, _} = JustBash.exec(bash, "echo -n '#{long_line}' | fold")
      lines = String.split(result.stdout, "\n", trim: true)
      assert length(lines) == 2
      assert String.length(hd(lines)) == 80
    end

    test "fold wraps at specified width with -w" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n 'hello world' | fold -w 5")
      assert result.stdout == "hello\n worl\nd"
    end

    test "fold with -s breaks at spaces" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello world test' | fold -sw 10")
      assert result.stdout =~ "hello "
    end

    test "fold from file" do
      bash = JustBash.new(files: %{"/test.txt" => "abcdefghij\n"})
      {result, _} = JustBash.exec(bash, "fold -w 5 /test.txt")
      assert result.stdout == "abcde\nfghij\n"
    end

    test "fold handles file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "fold /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "paste command" do
    test "paste merges lines from two files side by side" do
      bash = JustBash.new(files: %{"/a.txt" => "1\n2\n3\n", "/b.txt" => "a\nb\nc\n"})
      {result, _} = JustBash.exec(bash, "paste /a.txt /b.txt")
      assert result.stdout == "1\ta\n2\tb\n3\tc\n"
      assert result.exit_code == 0
    end

    test "paste handles files with different lengths" do
      bash = JustBash.new(files: %{"/a.txt" => "1\n2\n", "/b.txt" => "a\nb\nc\nd\n"})
      {result, _} = JustBash.exec(bash, "paste /a.txt /b.txt")
      assert result.stdout == "1\ta\n2\tb\n\tc\n\td\n"
    end

    test "paste with custom delimiter -d" do
      bash = JustBash.new(files: %{"/a.txt" => "1\n2\n", "/b.txt" => "a\nb\n"})
      {result, _} = JustBash.exec(bash, "paste -d ',' /a.txt /b.txt")
      assert result.stdout == "1,a\n2,b\n"
    end

    test "paste with -s serial mode" do
      bash = JustBash.new(files: %{"/a.txt" => "1\n2\n3\n"})
      {result, _} = JustBash.exec(bash, "paste -s /a.txt")
      assert result.stdout == "1\t2\t3\n"
    end

    test "paste reads from stdin with -" do
      bash = JustBash.new(files: %{"/a.txt" => "a\nb\n"})
      {result, _} = JustBash.exec(bash, "echo -e '1\\n2' | paste - /a.txt")
      assert result.stdout == "1\ta\n2\tb\n"
    end

    test "paste errors on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "paste /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "paste errors with no files" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "paste")
      assert result.exit_code == 1
      assert result.stderr =~ "usage"
    end
  end

  describe "comm command" do
    test "comm compares two sorted files showing three columns" do
      bash = JustBash.new(files: %{"/a.txt" => "a\nb\nc\n", "/b.txt" => "b\nc\nd\n"})
      {result, _} = JustBash.exec(bash, "comm /a.txt /b.txt")
      assert result.stdout =~ "a\n"
      assert result.stdout =~ "\t\tb\n"
      assert result.stdout =~ "\t\tc\n"
      assert result.stdout =~ "\td\n"
      assert result.exit_code == 0
    end

    test "comm with -1 suppresses first column" do
      bash = JustBash.new(files: %{"/a.txt" => "a\nb\n", "/b.txt" => "b\nc\n"})
      {result, _} = JustBash.exec(bash, "comm -1 /a.txt /b.txt")
      refute result.stdout =~ "a\n"
      assert result.stdout =~ "\tb\n"
      assert result.stdout =~ "c\n"
    end

    test "comm with -2 suppresses second column" do
      bash = JustBash.new(files: %{"/a.txt" => "a\nb\n", "/b.txt" => "b\nc\n"})
      {result, _} = JustBash.exec(bash, "comm -2 /a.txt /b.txt")
      assert result.stdout =~ "a\n"
      assert result.stdout =~ "\tb\n"
      refute result.stdout =~ "c"
    end

    test "comm with -3 suppresses third column" do
      bash = JustBash.new(files: %{"/a.txt" => "a\nb\n", "/b.txt" => "b\nc\n"})
      {result, _} = JustBash.exec(bash, "comm -3 /a.txt /b.txt")
      assert result.stdout =~ "a\n"
      assert result.stdout =~ "\tc\n"
      refute result.stdout =~ "b"
    end

    test "comm with -12 shows only lines in both files" do
      bash = JustBash.new(files: %{"/a.txt" => "a\nb\nc\n", "/b.txt" => "b\nc\nd\n"})
      {result, _} = JustBash.exec(bash, "comm -12 /a.txt /b.txt")
      assert result.stdout == "b\nc\n"
    end

    test "comm errors on missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "comm /a.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end

    test "comm errors on missing file" do
      bash = JustBash.new(files: %{"/a.txt" => "a\n"})
      {result, _} = JustBash.exec(bash, "comm /a.txt /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "expand command" do
    test "expand converts tabs to spaces" do
      bash = JustBash.new(files: %{"/test.txt" => "a\tb\tc\n"})
      {result, _} = JustBash.exec(bash, "expand /test.txt")
      refute result.stdout =~ "\t"
      assert result.exit_code == 0
    end

    test "expand uses default tab stop of 8" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\tb' | expand")
      assert result.stdout == "a       b"
    end

    test "expand with custom tab stop -t" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\tb' | expand -t 4")
      assert result.stdout == "a   b"
    end

    test "expand with -i only expands leading tabs" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '\\ta\\tb' | expand -i")
      assert result.stdout =~ "a\tb"
    end

    test "expand from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'x\\ty' | expand -t 2")
      assert result.stdout == "x y\n"
    end

    test "expand errors on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "expand /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "expand errors on invalid tab size" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "expand -t abc")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid tab size"
    end
  end
end
