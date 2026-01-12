defmodule JustBash.IntegrationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration tests for realistic bash pipelines and multi-command workflows.
  These tests verify that commands work well together in common use cases.
  """

  describe "text processing pipelines" do
    test "sort | uniq to find unique sorted values" do
      bash = JustBash.new(files: %{"/data.txt" => "banana\napple\napple\ncherry\nbanana\n"})
      {result, _} = JustBash.exec(bash, "sort /data.txt | uniq")
      assert result.stdout == "apple\nbanana\ncherry\n"
    end

    test "sort | uniq -c to count occurrences" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\na\na\nb\nc\n"})
      {result, _} = JustBash.exec(bash, "sort /data.txt | uniq -c | sort -rn")
      lines = String.split(result.stdout, "\n", trim: true)
      assert hd(lines) =~ "3"
      assert hd(lines) =~ "a"
    end

    test "cat | grep | wc -l to count matching lines" do
      bash =
        JustBash.new(
          files: %{"/log.txt" => "ERROR: failed\nINFO: ok\nERROR: timeout\nINFO: done\n"}
        )

      {result, _} = JustBash.exec(bash, "cat /log.txt | grep ERROR | wc -l")
      assert String.trim(result.stdout) == "2"
    end

    test "grep | cut to extract fields from matches" do
      bash =
        JustBash.new(
          files: %{"/users.txt" => "admin:x:0:root\nuser:x:1000:john\nguest:x:1001:guest\n"}
        )

      {result, _} = JustBash.exec(bash, "grep -v admin /users.txt | cut -d: -f1")
      assert result.stdout =~ "user"
      assert result.stdout =~ "guest"
    end

    test "seq | head | tail to get middle range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 100 | head -20 | tail -5")
      assert result.stdout == "16\n17\n18\n19\n20\n"
    end

    test "echo | tr to convert case" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'Hello World' | tr 'A-Z' 'a-z'")
      assert result.stdout == "hello world\n"
    end

    test "cat | sed | grep for filtered transformation" do
      bash =
        JustBash.new(files: %{"/config.txt" => "key1=value1\nkey2=value2\n"})

      {result, _} = JustBash.exec(bash, "cat /config.txt | sed 's/=/ -> /'")
      assert result.stdout == "key1 -> value1\nkey2 -> value2\n"
    end

    test "sort -rn to sort scores" do
      bash = JustBash.new(files: %{"/scores.txt" => "85\n92\n78\n"})
      {result, _} = JustBash.exec(bash, "sort -rn /scores.txt | head -1")
      assert result.stdout == "92\n"
    end
  end

  describe "file manipulation pipelines" do
    test "find pattern and process with xargs" do
      bash =
        JustBash.new(
          files: %{
            "/project/src/a.txt" => "content-a",
            "/project/src/b.txt" => "content-b",
            "/project/readme.md" => "readme"
          }
        )

      {result, _} = JustBash.exec(bash, "find /project -name '*.txt' | xargs cat")
      assert result.stdout =~ "content-a"
      assert result.stdout =~ "content-b"
      refute result.stdout =~ "readme"
    end

    test "ls | grep to filter file listing" do
      bash =
        JustBash.new(
          files: %{
            "/dir/file.txt" => "a",
            "/dir/data.csv" => "b",
            "/dir/notes.txt" => "c"
          }
        )

      {result, _} = JustBash.exec(bash, "ls /dir | grep txt")
      assert result.stdout =~ "file.txt"
      assert result.stdout =~ "notes.txt"
      refute result.stdout =~ "csv"
    end

    test "create directory structure and verify" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, """
        mkdir -p /project/src/main
        mkdir -p /project/src/test
        mkdir -p /project/docs
        touch /project/src/main/app.txt
        touch /project/src/test/test.txt
        """)

      {result, _} = JustBash.exec(bash, "find /project -type f")
      assert result.stdout =~ "app.txt"
      assert result.stdout =~ "test.txt"
    end

    test "copy multiple files to directory" do
      bash = JustBash.new(files: %{"/a.txt" => "a", "/b.txt" => "b"})
      {_, bash} = JustBash.exec(bash, "mkdir /dest")
      {_, bash} = JustBash.exec(bash, "cp /a.txt /dest/a.txt")
      {_, bash} = JustBash.exec(bash, "cp /b.txt /dest/b.txt")
      {result, _} = JustBash.exec(bash, "ls /dest")
      assert result.stdout =~ "a.txt"
      assert result.stdout =~ "b.txt"
    end
  end

  describe "shell scripting patterns" do
    test "conditional file processing" do
      bash = JustBash.new(files: %{"/data.txt" => "some content"})

      {result, _} =
        JustBash.exec(bash, """
        if [ -f /data.txt ]; then
          echo "processing data"
          cat /data.txt
        else
          echo "no data found"
        fi
        """)

      assert result.stdout =~ "processing data"
      assert result.stdout =~ "some content"
    end

    test "loop through files" do
      bash = JustBash.new(files: %{"/dir/a.txt" => "1", "/dir/b.txt" => "2", "/dir/c.txt" => "3"})

      {result, _} =
        JustBash.exec(bash, """
        for f in a b c; do
          echo "File: $f"
        done
        """)

      assert result.stdout =~ "File: a"
      assert result.stdout =~ "File: b"
      assert result.stdout =~ "File: c"
    end

    test "while loop counter" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        count=0
        while [ $count -lt 5 ]; do
          echo $count
          count=$((count + 1))
        done
        """)

      assert result.stdout == "0\n1\n2\n3\n4\n"
    end

    test "command substitution in pipeline" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"Current dir: $(pwd)\"")
      assert result.stdout == "Current dir: /home/user\n"
    end

    test "variable expansion in commands" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        FILE=/test.txt
        echo "hello" > $FILE
        cat $FILE
        """)

      assert result.stdout == "hello\n"
    end

    test "error handling with || operator" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cat /nonexistent 2>/dev/null || echo 'File not found'")
      assert result.stdout == "File not found\n"
    end

    test "chained commands with && for success-dependent execution" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "mkdir /testdir && touch /testdir/file.txt && echo 'Created'")

      assert result.stdout == "Created\n"
    end
  end

  describe "data transformation pipelines" do
    test "CSV processing with cut and sort" do
      csv = "name,score,grade\nalice,95,A\nbob,82,B\ncharlie,78,C\ndave,95,A\n"
      bash = JustBash.new(files: %{"/data.csv" => csv})
      {result, _} = JustBash.exec(bash, "tail -n +2 /data.csv | cut -d, -f2 | sort -rn | head -1")
      assert result.stdout == "95\n"
    end

    test "log analysis pipeline" do
      log = """
      2024-01-01 ERROR connection failed
      2024-01-01 INFO request processed
      2024-01-02 ERROR timeout
      2024-01-02 INFO success
      2024-01-02 ERROR database error
      """

      bash = JustBash.new(files: %{"/app.log" => log})
      {result, _} = JustBash.exec(bash, "grep ERROR /app.log | wc -l")
      assert String.trim(result.stdout) == "3"
    end

    test "word frequency analysis" do
      text = "the\nthe\nthe\nfox\nfox\ndog\n"
      bash = JustBash.new(files: %{"/words.txt" => text})
      {result, _} = JustBash.exec(bash, "sort /words.txt | uniq -c | sort -rn")
      lines = String.split(result.stdout, "\n", trim: true)
      assert hd(lines) =~ "the"
    end

    test "extract and transform specific lines" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\nline4\nline5\n"})
      {result, _} = JustBash.exec(bash, "sed -n '2,4p' /data.txt | tr 'a-z' 'A-Z'")
      assert result.stdout == "LINE2\nLINE3\nLINE4\n"
    end
  end

  describe "system info and environment" do
    test "environment variable chain" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        export PROJECT=myapp
        export VERSION=1.0
        echo "$PROJECT-$VERSION"
        """)

      assert result.stdout == "myapp-1.0\n"
    end

    test "path manipulation" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        FILE=/path/to/myfile.txt
        echo "Directory: $(dirname $FILE)"
        echo "Filename: $(basename $FILE)"
        echo "Without ext: $(basename $FILE .txt)"
        """)

      assert result.stdout =~ "Directory: /path/to"
      assert result.stdout =~ "Filename: myfile.txt"
      assert result.stdout =~ "Without ext: myfile"
    end

    test "conditional based on exit code" do
      bash = JustBash.new(files: %{"/exists.txt" => "content"})

      {result, _} =
        JustBash.exec(bash, """
        cat /exists.txt > /dev/null
        if [ $? -eq 0 ]; then
          echo "success"
        else
          echo "failed"
        fi
        """)

      assert result.stdout == "success\n"
    end
  end

  describe "tee and multiple output" do
    test "tee to save intermediate results" do
      bash = JustBash.new(files: %{"/nums.txt" => "3\n1\n4\n1\n5\n"})
      {result, bash} = JustBash.exec(bash, "sort /nums.txt | tee /sorted.txt | uniq")
      assert result.stdout == "1\n3\n4\n5\n"

      {result2, _} = JustBash.exec(bash, "cat /sorted.txt")
      assert result2.stdout == "1\n1\n3\n4\n5\n"
    end

    test "pipeline with multiple transformations" do
      data = "user1:admin:active\nuser2:guest:inactive\nuser3:admin:active\n"
      bash = JustBash.new(files: %{"/users.txt" => data})

      {result, _} =
        JustBash.exec(bash, "grep active /users.txt | grep admin | cut -d: -f1 | sort")

      assert result.stdout == "user1\nuser3\n"
    end
  end

  describe "awk processing" do
    test "awk field extraction" do
      data = "alice 85 A\nbob 72 C\ncharlie 91 A\ndave 68 D\n"
      bash = JustBash.new(files: %{"/scores.txt" => data})
      {result, _} = JustBash.exec(bash, "awk '{print $1}' /scores.txt")
      assert result.stdout == "alice\nbob\ncharlie\ndave\n"
    end

    test "awk with custom field separator" do
      data = "alice:engineering:75000\nbob:sales:65000\ncharlie:engineering:80000\n"
      bash = JustBash.new(files: %{"/employees.csv" => data})

      {result, _} =
        JustBash.exec(bash, "awk -F: '$2==\"engineering\" {print $1, $3}' /employees.csv")

      assert result.stdout == "alice 75000\ncharlie 80000\n"
    end

    test "awk BEGIN and END blocks" do
      data = "10\n20\n30\n40\n"
      bash = JustBash.new(files: %{"/nums.txt" => data})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN{sum=0}{sum+=$1}END{print \"Total:\", sum}' /nums.txt"
        )

      assert result.stdout =~ "Total:"
      assert result.stdout =~ "100"
    end
  end

  describe "sed transformations" do
    test "sed multiple substitutions" do
      bash = JustBash.new(files: %{"/template.txt" => "Hello NAME, welcome to PLACE!\n"})

      {result, _} =
        JustBash.exec(bash, "sed -e 's/NAME/World/' -e 's/PLACE/Earth/' /template.txt")

      assert result.stdout == "Hello World, welcome to Earth!\n"
    end

    test "sed line deletion and printing" do
      bash = JustBash.new(files: %{"/data.txt" => "header\ndata1\ndata2\nfooter\n"})
      {result, _} = JustBash.exec(bash, "sed '1d;$d' /data.txt")
      assert result.stdout == "data1\ndata2\n"
    end

    test "sed in-place modification" do
      bash = JustBash.new(files: %{"/file.txt" => "old value\n"})
      {_, bash} = JustBash.exec(bash, "sed -i 's/old/new/' /file.txt")
      {result, _} = JustBash.exec(bash, "cat /file.txt")
      assert result.stdout == "new value\n"
    end
  end

  describe "complex real-world scenarios" do
    test "build script simulation" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        mkdir -p /build/output
        echo "Building..." > /build/output/build.log
        echo "Done" >> /build/output/build.log
        cat /build/output/build.log
        """)

      assert result.stdout == "Building...\nDone\n"
    end

    test "configuration file parsing" do
      config = "DB_HOST=localhost\nDB_PORT=5432\nDB_NAME=mydb\n"

      bash = JustBash.new(files: %{"/app.conf" => config})
      {result, _} = JustBash.exec(bash, "cat /app.conf | cut -d= -f2")
      lines = String.split(result.stdout, "\n", trim: true)
      assert "localhost" in lines
      assert "5432" in lines
      assert "mydb" in lines
    end

    test "cleanup script" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/file1.tmp" => "temp1",
            "/tmp/file2.tmp" => "temp2",
            "/keep/important.txt" => "keep this"
          }
        )

      {_, bash} = JustBash.exec(bash, "rm /tmp/file1.tmp")
      {_, bash} = JustBash.exec(bash, "rm /tmp/file2.tmp")
      {result, _} = JustBash.exec(bash, "ls /tmp")
      refute result.stdout =~ "file1.tmp"

      {result2, _} = JustBash.exec(bash, "cat /keep/important.txt")
      assert result2.stdout == "keep this"
    end
  end
end
