defmodule JustBash.Commands.FileInfoTest do
  use ExUnit.Case, async: true

  describe "stat command" do
    test "stat shows file information" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "stat /test.txt")
      assert result.stdout =~ "File: /test.txt"
      assert result.stdout =~ "Size: 5"
      assert result.exit_code == 0
    end

    test "stat with -c format" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "stat -c '%n %s' /test.txt")
      assert result.stdout == "/test.txt 5\n"
    end

    test "stat shows directory" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "test"})
      {result, _} = JustBash.exec(bash, "stat /dir")
      assert result.stdout =~ "File: /dir"
      assert result.exit_code == 0
    end

    test "stat errors on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "stat /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "stat missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "stat")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end
  end

  describe "file command" do
    test "file detects directory" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "file /dir")
      assert result.stdout =~ "directory"
      assert result.exit_code == 0
    end

    test "file detects empty file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "file /empty.txt")
      assert result.stdout =~ "empty"
    end

    test "file detects shell script by shebang" do
      bash = JustBash.new(files: %{"/script" => "#!/bin/bash\necho hello"})
      {result, _} = JustBash.exec(bash, "file /script")
      assert result.stdout =~ "shell script"
    end

    test "file detects python script by shebang" do
      bash = JustBash.new(files: %{"/script.py" => "#!/usr/bin/env python3\nprint('hi')"})
      {result, _} = JustBash.exec(bash, "file /script.py")
      assert result.stdout =~ "Python"
    end

    test "file detects JSON by extension" do
      bash = JustBash.new(files: %{"/data.json" => "{\"key\": \"value\"}"})
      {result, _} = JustBash.exec(bash, "file /data.json")
      assert result.stdout =~ "JSON"
    end

    test "file with -b shows brief output" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "file -b /test.txt")
      refute result.stdout =~ "/test.txt"
    end

    test "file with -i shows mime type" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "file -i /test.txt")
      assert result.stdout =~ "text/plain"
    end

    test "file errors on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "file /nonexistent")
      assert result.exit_code == 1
      assert result.stdout =~ "cannot open"
    end

    test "file errors with no arguments" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "file")
      assert result.exit_code == 1
      assert result.stderr =~ "Usage"
    end
  end

  describe "find command" do
    test "find lists all files in directory" do
      bash = JustBash.new(files: %{"/dir/file1.txt" => "a", "/dir/file2.txt" => "b"})
      {result, _} = JustBash.exec(bash, "find /dir")
      assert result.stdout =~ "/dir"
      assert result.stdout =~ "file1.txt"
      assert result.stdout =~ "file2.txt"
      assert result.exit_code == 0
    end

    test "find with -name filters by pattern" do
      bash = JustBash.new(files: %{"/dir/test.txt" => "a", "/dir/test.md" => "b"})
      {result, _} = JustBash.exec(bash, "find /dir -name '*.txt'")
      assert result.stdout =~ "test.txt"
      refute result.stdout =~ "test.md"
    end

    test "find with -iname does case insensitive match" do
      bash = JustBash.new(files: %{"/dir/TEST.txt" => "a", "/dir/other.txt" => "b"})
      {result, _} = JustBash.exec(bash, "find /dir -iname 'test*'")
      assert result.stdout =~ "TEST.txt"
    end

    test "find with -type f finds only files" do
      bash = JustBash.new(files: %{"/dir/subdir/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "find /dir -type f")
      assert result.stdout =~ "file.txt"
      refute String.contains?(result.stdout, "subdir\n")
    end

    test "find with -type d finds only directories" do
      bash = JustBash.new(files: %{"/dir/subdir/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "find /dir -type d")
      assert result.stdout =~ "/dir"
      assert result.stdout =~ "subdir"
      refute result.stdout =~ "file.txt"
    end

    test "find with -maxdepth limits depth" do
      bash = JustBash.new(files: %{"/dir/sub1/sub2/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "find /dir -maxdepth 1")
      assert result.stdout =~ "/dir"
      assert result.stdout =~ "sub1"
      refute result.stdout =~ "sub2"
    end

    test "find with -mindepth skips shallow entries" do
      bash = JustBash.new(files: %{"/dir/sub/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "find /dir -mindepth 2")
      refute result.stdout =~ "/dir\n"
      refute String.contains?(result.stdout, "sub\n")
      assert result.stdout =~ "file.txt"
    end

    test "find with -empty finds empty files" do
      bash = JustBash.new(files: %{"/dir/empty.txt" => "", "/dir/nonempty.txt" => "data"})
      {result, _} = JustBash.exec(bash, "find /dir -type f -empty")
      assert result.stdout =~ "empty.txt"
      refute result.stdout =~ "nonempty.txt"
    end

    test "find with -print0 uses null separator" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "find /dir -print0")
      assert result.stdout =~ "\0"
    end

    test "find defaults to current directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "find")
      assert result.stdout =~ "."
      assert result.exit_code == 0
    end

    test "find errors on nonexistent path" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "find /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "tree command" do
    test "tree shows directory structure" do
      bash = JustBash.new(files: %{"/dir/file1.txt" => "a", "/dir/file2.txt" => "b"})
      {result, _} = JustBash.exec(bash, "tree /dir")
      assert result.stdout =~ "/dir"
      assert result.stdout =~ "file1.txt"
      assert result.stdout =~ "file2.txt"
      assert result.exit_code == 0
    end

    test "tree shows summary at end" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "tree /dir")
      assert result.stdout =~ "director"
      assert result.stdout =~ "file"
    end

    test "tree with -a shows hidden files" do
      bash = JustBash.new(files: %{"/dir/.hidden" => "a", "/dir/visible" => "b"})
      {result, _} = JustBash.exec(bash, "tree -a /dir")
      assert result.stdout =~ ".hidden"
      assert result.stdout =~ "visible"
    end

    test "tree without -a hides dotfiles" do
      bash = JustBash.new(files: %{"/dir/.hidden" => "a", "/dir/visible" => "b"})
      {result, _} = JustBash.exec(bash, "tree /dir")
      refute result.stdout =~ ".hidden"
      assert result.stdout =~ "visible"
    end

    test "tree with -d shows only directories" do
      bash = JustBash.new(files: %{"/dir/subdir/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "tree -d /dir")
      assert result.stdout =~ "subdir"
      refute result.stdout =~ "file.txt"
    end

    test "tree with -L limits depth" do
      bash = JustBash.new(files: %{"/dir/sub1/sub2/file.txt" => "a"})
      {result, _} = JustBash.exec(bash, "tree -L 1 /dir")
      assert result.stdout =~ "sub1"
      refute result.stdout =~ "sub2"
    end

    test "tree errors on nonexistent directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "tree /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "du command" do
    test "du shows directory size" do
      bash = JustBash.new(files: %{"/dir/file1.txt" => "hello", "/dir/file2.txt" => "world"})
      {result, _} = JustBash.exec(bash, "du /dir")
      assert result.stdout =~ "/dir"
      assert result.exit_code == 0
    end

    test "du with -s summarizes" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "test"})
      {result, _} = JustBash.exec(bash, "du -s /dir")
      lines = String.split(result.stdout, "\n", trim: true)
      assert length(lines) == 1
      assert hd(lines) =~ "/dir"
    end

    test "du with -h shows human readable" do
      bash = JustBash.new(files: %{"/test.txt" => String.duplicate("a", 2048)})
      {result, _} = JustBash.exec(bash, "du -h /test.txt")
      assert result.stdout =~ "K" or result.stdout =~ "2"
    end

    test "du errors on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "du /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "du defaults to current directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "du")
      assert result.stdout =~ "."
      assert result.exit_code == 0
    end
  end

  describe "diff command" do
    test "diff shows no output for identical files" do
      bash = JustBash.new(files: %{"/a.txt" => "hello\nworld\n", "/b.txt" => "hello\nworld\n"})
      {result, _} = JustBash.exec(bash, "diff /a.txt /b.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "diff shows differences between files" do
      bash = JustBash.new(files: %{"/a.txt" => "hello\n", "/b.txt" => "world\n"})
      {result, _} = JustBash.exec(bash, "diff /a.txt /b.txt")
      assert result.stdout =~ "-hello"
      assert result.stdout =~ "+world"
      assert result.exit_code == 1
    end

    test "diff with -q shows brief output" do
      bash = JustBash.new(files: %{"/a.txt" => "hello\n", "/b.txt" => "world\n"})
      {result, _} = JustBash.exec(bash, "diff -q /a.txt /b.txt")
      assert result.stdout =~ "differ"
      assert result.exit_code == 1
    end

    test "diff with -s reports identical files" do
      bash = JustBash.new(files: %{"/a.txt" => "hello\n", "/b.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "diff -s /a.txt /b.txt")
      assert result.stdout =~ "identical"
      assert result.exit_code == 0
    end

    test "diff with -i ignores case" do
      bash = JustBash.new(files: %{"/a.txt" => "HELLO\n", "/b.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "diff -i /a.txt /b.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "diff errors on missing file" do
      bash = JustBash.new(files: %{"/a.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "diff /a.txt /nonexistent")
      assert result.exit_code == 2
      assert result.stderr =~ "No such file"
    end

    test "diff errors on missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "diff /a.txt")
      assert result.exit_code == 2
      assert result.stderr =~ "missing operand"
    end
  end

  describe "md5sum command" do
    test "md5sum computes hash of file" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "md5sum /test.txt")
      assert result.stdout =~ "5d41402abc4b2a76b9719d911017c592"
      assert result.stdout =~ "/test.txt"
      assert result.exit_code == 0
    end

    test "md5sum computes hash from stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n 'hello' | md5sum")
      assert result.stdout =~ "5d41402abc4b2a76b9719d911017c592"
    end

    test "md5sum handles multiple files" do
      bash = JustBash.new(files: %{"/a.txt" => "hello", "/b.txt" => "world"})
      {result, _} = JustBash.exec(bash, "md5sum /a.txt /b.txt")
      assert result.stdout =~ "/a.txt"
      assert result.stdout =~ "/b.txt"
      lines = String.split(result.stdout, "\n", trim: true)
      assert length(lines) == 2
    end

    test "md5sum with -c checks hashes" do
      bash =
        JustBash.new(
          files: %{
            "/test.txt" => "hello",
            "/checksums.md5" => "5d41402abc4b2a76b9719d911017c592  /test.txt\n"
          }
        )

      {result, _} = JustBash.exec(bash, "md5sum -c /checksums.md5")
      assert result.stdout =~ "/test.txt: OK"
      assert result.exit_code == 0
    end

    test "md5sum with -c detects mismatch" do
      bash =
        JustBash.new(
          files: %{
            "/test.txt" => "modified",
            "/checksums.md5" => "5d41402abc4b2a76b9719d911017c592  /test.txt\n"
          }
        )

      {result, _} = JustBash.exec(bash, "md5sum -c /checksums.md5")
      assert result.stdout =~ "FAILED"
      assert result.exit_code == 1
    end

    test "md5sum errors on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "md5sum /nonexistent")
      assert result.exit_code == 1
      assert result.stdout =~ "No such file"
    end
  end

  describe "base64 command" do
    test "base64 encodes stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n 'hello' | base64")
      assert result.stdout =~ "aGVsbG8="
    end

    test "base64 decodes with -d" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n 'aGVsbG8=' | base64 -d")
      assert result.stdout == "hello"
    end

    test "base64 encodes file" do
      bash = JustBash.new(files: %{"/test.txt" => "test"})
      {result, _} = JustBash.exec(bash, "base64 /test.txt")
      assert result.stdout =~ "dGVzdA=="
    end

    test "base64 handles file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "base64 /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end
end
