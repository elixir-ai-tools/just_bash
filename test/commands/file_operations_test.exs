defmodule JustBash.Commands.FileOperationsTest do
  use ExUnit.Case, async: true

  describe "ls command" do
    test "ls nonexistent directory fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ls /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

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

  describe "cp command" do
    test "cp copies file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {result, bash} = JustBash.exec(bash, "cp /src.txt /dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "content"
    end

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
    test "mv moves file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {result, bash} = JustBash.exec(bash, "mv /src.txt /dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "content"

      {result3, _} = JustBash.exec(bash, "cat /src.txt")
      assert result3.exit_code == 1
    end

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

  describe "touch command" do
    test "touch existing file succeeds" do
      bash = JustBash.new(files: %{"/home/user/existing.txt" => "content"})
      {result, _} = JustBash.exec(bash, "touch /home/user/existing.txt")
      assert result.exit_code == 0
    end

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

  describe "ln command" do
    test "ln creates a symbolic link with -s" do
      bash = JustBash.new(files: %{"/target.txt" => "hello world\n"})
      {result, new_bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /link.txt")
      assert cat_result.stdout == "hello world\n"
    end

    test "ln creates a relative symbolic link" do
      bash = JustBash.new(files: %{"/dir/target.txt" => "content\n"})
      {result, new_bash} = JustBash.exec(bash, "ln -s target.txt /dir/link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /dir/link.txt")
      assert cat_result.stdout == "content\n"
    end

    test "ln allows dangling symlinks" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "ln -s /nonexistent /link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /link.txt")
      assert cat_result.exit_code == 1
    end

    test "ln errors if link already exists" do
      bash = JustBash.new(files: %{"/target.txt" => "hello\n", "/link.txt" => "existing\n"})
      {result, _} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "File exists"
    end

    test "ln with -f overwrites existing link" do
      bash =
        JustBash.new(files: %{"/target.txt" => "new content\n", "/link.txt" => "old content\n"})

      {result, new_bash} = JustBash.exec(bash, "ln -sf /target.txt /link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /link.txt")
      assert cat_result.stdout == "new content\n"
    end

    test "ln creates hard link" do
      bash = JustBash.new(files: %{"/original.txt" => "hello world\n"})
      {result, new_bash} = JustBash.exec(bash, "ln /original.txt /hardlink.txt")
      assert result.exit_code == 0

      {orig, _} = JustBash.exec(new_bash, "cat /original.txt")
      {link, _} = JustBash.exec(new_bash, "cat /hardlink.txt")
      assert link.stdout == orig.stdout
    end

    test "ln hard link errors when target does not exist" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ln /nonexistent.txt /link.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "ln hard link errors for directory" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "test\n"})
      {result, _} = JustBash.exec(bash, "ln /dir /dirlink")
      assert result.exit_code == 1
      assert result.stderr =~ "not allowed"
    end

    test "ln errors on missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ln")
      assert result.exit_code == 1
      assert result.stderr =~ "missing file operand"
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

  describe "readlink command" do
    test "readlink reads symlink target" do
      bash = JustBash.new(files: %{"/target.txt" => "hello\n"})
      {_, new_bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      {result, _} = JustBash.exec(new_bash, "readlink /link.txt")
      assert result.stdout == "/target.txt\n"
      assert result.exit_code == 0
    end

    test "readlink reads relative symlink target" do
      bash = JustBash.new(files: %{"/dir/target.txt" => "hello\n"})
      {_, new_bash} = JustBash.exec(bash, "ln -s target.txt /dir/link.txt")
      {result, _} = JustBash.exec(new_bash, "readlink /dir/link.txt")
      assert result.stdout == "target.txt\n"
    end

    test "readlink with -f resolves full path" do
      bash = JustBash.new(files: %{"/dir/target.txt" => "hello\n"})
      {_, new_bash} = JustBash.exec(bash, "ln -s target.txt /dir/link.txt")
      {result, _} = JustBash.exec(new_bash, "readlink -f /dir/link.txt")
      assert result.stdout == "/dir/target.txt\n"
    end

    test "readlink errors on non-symlink without -f" do
      bash = JustBash.new(files: %{"/regular.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "readlink /regular.txt")
      assert result.exit_code == 1
    end

    test "readlink missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "readlink")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end
  end
end
