defmodule JustBash.FS.InMemoryFSTest do
  use ExUnit.Case, async: true

  alias JustBash.FS
  alias JustBash.FS.InMemoryFS

  describe "new/1" do
    test "creates filesystem with root directory" do
      fs = InMemoryFS.new()
      assert InMemoryFS.exists?(fs, "/")
    end

    test "creates filesystem with initial files" do
      fs = InMemoryFS.new(%{"/home/user/file.txt" => "hello"})
      assert {:ok, "hello"} = InMemoryFS.read_file(fs, "/home/user/file.txt")
    end

    test "creates filesystem with extended file init" do
      fs = InMemoryFS.new(%{"/bin/script" => %{content: "#!/bin/bash", mode: 0o755}})
      assert {:ok, stat} = InMemoryFS.stat(fs, "/bin/script")
      assert stat.mode == 0o755
    end

    test "creates parent directories automatically" do
      fs = InMemoryFS.new(%{"/a/b/c/file.txt" => "content"})
      assert InMemoryFS.exists?(fs, "/a")
      assert InMemoryFS.exists?(fs, "/a/b")
      assert InMemoryFS.exists?(fs, "/a/b/c")
    end
  end

  describe "normalize_path/1" do
    test "handles root path" do
      assert FS.normalize_path("/") == "/"
      assert FS.normalize_path("") == "/"
    end

    test "removes trailing slashes" do
      assert FS.normalize_path("/home/user/") == "/home/user"
    end

    test "ensures leading slash" do
      assert FS.normalize_path("home/user") == "/home/user"
    end

    test "resolves . and .." do
      assert FS.normalize_path("/home/user/../user/./file") == "/home/user/file"
      assert FS.normalize_path("/home/../etc") == "/etc"
      assert FS.normalize_path("/home/user/../../") == "/"
    end

    test "handles multiple slashes" do
      assert FS.normalize_path("//home//user//") == "/home/user"
    end
  end

  describe "dirname/1" do
    test "returns parent directory" do
      assert FS.dirname("/home/user/file.txt") == "/home/user"
      assert FS.dirname("/home/user") == "/home"
    end

    test "returns root for top-level paths" do
      assert FS.dirname("/file.txt") == "/"
      assert FS.dirname("/") == "/"
    end
  end

  describe "basename/1" do
    test "returns file name" do
      assert FS.basename("/home/user/file.txt") == "file.txt"
      assert FS.basename("/home/user") == "user"
    end

    test "handles root" do
      assert FS.basename("/") == "/"
    end
  end

  describe "resolve_path/2" do
    test "resolves absolute paths" do
      assert FS.resolve_path("/home/user", "/etc/passwd") == "/etc/passwd"
    end

    test "resolves relative paths" do
      assert FS.resolve_path("/home/user", "file.txt") == "/home/user/file.txt"
      assert FS.resolve_path("/home/user", "subdir/file") == "/home/user/subdir/file"
    end

    test "handles root base" do
      assert FS.resolve_path("/", "file.txt") == "/file.txt"
    end
  end

  describe "write_file/4 and read_file/2" do
    test "writes and reads file content" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.write_file(fs, "/test.txt", "hello world")
      assert {:ok, "hello world"} = InMemoryFS.read_file(fs, "/test.txt")
    end

    test "creates parent directories" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.write_file(fs, "/a/b/c/file.txt", "content")
      assert InMemoryFS.exists?(fs, "/a/b/c")
    end

    test "overwrites existing files" do
      fs = InMemoryFS.new(%{"/file.txt" => "old"})
      {:ok, fs} = InMemoryFS.write_file(fs, "/file.txt", "new")
      assert {:ok, "new"} = InMemoryFS.read_file(fs, "/file.txt")
    end

    test "read_file returns error for nonexistent file" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.read_file(fs, "/nonexistent")
    end

    test "read_file returns error for directory" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/mydir")
      assert {:error, :eisdir} = InMemoryFS.read_file(fs, "/mydir")
    end

    test "writes with custom mode" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.write_file(fs, "/script.sh", "#!/bin/bash", mode: 0o755)
      {:ok, stat} = InMemoryFS.stat(fs, "/script.sh")
      assert stat.mode == 0o755
    end
  end

  describe "append_file/3" do
    test "appends to existing file" do
      fs = InMemoryFS.new(%{"/file.txt" => "hello"})
      {:ok, fs} = InMemoryFS.append_file(fs, "/file.txt", " world")
      assert {:ok, "hello world"} = InMemoryFS.read_file(fs, "/file.txt")
    end

    test "creates file if it doesn't exist" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.append_file(fs, "/new.txt", "content")
      assert {:ok, "content"} = InMemoryFS.read_file(fs, "/new.txt")
    end
  end

  describe "mkdir/3" do
    test "creates directory" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/mydir")
      assert InMemoryFS.exists?(fs, "/mydir")
      {:ok, stat} = InMemoryFS.stat(fs, "/mydir")
      assert stat.is_directory
    end

    test "returns error if exists" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/mydir")
      assert {:error, :eexist} = InMemoryFS.mkdir(fs, "/mydir")
    end

    test "succeeds with recursive on existing dir" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/mydir")
      assert {:ok, _} = InMemoryFS.mkdir(fs, "/mydir", recursive: true)
    end

    test "returns error if parent doesn't exist" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.mkdir(fs, "/a/b/c")
    end

    test "creates parent directories with recursive" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/a/b/c", recursive: true)
      assert InMemoryFS.exists?(fs, "/a")
      assert InMemoryFS.exists?(fs, "/a/b")
      assert InMemoryFS.exists?(fs, "/a/b/c")
    end
  end

  describe "readdir/2" do
    test "lists directory contents" do
      fs =
        InMemoryFS.new(%{
          "/dir/file1.txt" => "a",
          "/dir/file2.txt" => "b",
          "/dir/subdir/file3.txt" => "c"
        })

      {:ok, entries} = InMemoryFS.readdir(fs, "/dir")
      assert Enum.sort(entries) == ["file1.txt", "file2.txt", "subdir"]
    end

    test "returns error for nonexistent dir" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.readdir(fs, "/nonexistent")
    end

    test "returns error for file" do
      fs = InMemoryFS.new(%{"/file.txt" => "content"})
      assert {:error, :enotdir} = InMemoryFS.readdir(fs, "/file.txt")
    end

    test "lists root directory" do
      fs = InMemoryFS.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFS.mkdir(fs, "/dir")
      {:ok, entries} = InMemoryFS.readdir(fs, "/")
      assert "file.txt" in entries
      assert "dir" in entries
    end
  end

  describe "rm/3" do
    test "removes file" do
      fs = InMemoryFS.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFS.rm(fs, "/file.txt")
      refute InMemoryFS.exists?(fs, "/file.txt")
    end

    test "removes empty directory" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/emptydir")
      {:ok, fs} = InMemoryFS.rm(fs, "/emptydir")
      refute InMemoryFS.exists?(fs, "/emptydir")
    end

    test "returns error for nonempty directory" do
      fs = InMemoryFS.new(%{"/dir/file.txt" => "content"})
      assert {:error, :enotempty} = InMemoryFS.rm(fs, "/dir")
    end

    test "removes directory recursively" do
      fs =
        InMemoryFS.new(%{
          "/dir/file.txt" => "a",
          "/dir/subdir/nested.txt" => "b"
        })

      {:ok, fs} = InMemoryFS.rm(fs, "/dir", recursive: true)
      refute InMemoryFS.exists?(fs, "/dir")
      refute InMemoryFS.exists?(fs, "/dir/file.txt")
      refute InMemoryFS.exists?(fs, "/dir/subdir")
    end

    test "returns error for nonexistent" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.rm(fs, "/nonexistent")
    end

    test "succeeds with force on nonexistent" do
      fs = InMemoryFS.new()
      assert {:ok, _} = InMemoryFS.rm(fs, "/nonexistent", force: true)
    end
  end

  describe "cp/4" do
    test "copies file" do
      fs = InMemoryFS.new(%{"/src.txt" => "content"})
      {:ok, fs} = InMemoryFS.cp(fs, "/src.txt", "/dest.txt")
      assert {:ok, "content"} = InMemoryFS.read_file(fs, "/dest.txt")
      assert {:ok, "content"} = InMemoryFS.read_file(fs, "/src.txt")
    end

    test "returns error for nonexistent source" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.cp(fs, "/nonexistent", "/dest")
    end

    test "returns error copying directory without recursive" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/srcdir")
      assert {:error, :eisdir} = InMemoryFS.cp(fs, "/srcdir", "/destdir")
    end

    test "copies directory recursively" do
      fs =
        InMemoryFS.new(%{
          "/srcdir/file.txt" => "a",
          "/srcdir/subdir/nested.txt" => "b"
        })

      {:ok, fs} = InMemoryFS.cp(fs, "/srcdir", "/destdir", recursive: true)
      assert {:ok, "a"} = InMemoryFS.read_file(fs, "/destdir/file.txt")
      assert {:ok, "b"} = InMemoryFS.read_file(fs, "/destdir/subdir/nested.txt")
    end
  end

  describe "mv/3" do
    test "moves file" do
      fs = InMemoryFS.new(%{"/src.txt" => "content"})
      {:ok, fs} = InMemoryFS.mv(fs, "/src.txt", "/dest.txt")
      assert {:ok, "content"} = InMemoryFS.read_file(fs, "/dest.txt")
      refute InMemoryFS.exists?(fs, "/src.txt")
    end

    test "moves directory" do
      fs = InMemoryFS.new(%{"/srcdir/file.txt" => "content"})
      {:ok, fs} = InMemoryFS.mv(fs, "/srcdir", "/destdir")
      assert {:ok, "content"} = InMemoryFS.read_file(fs, "/destdir/file.txt")
      refute InMemoryFS.exists?(fs, "/srcdir")
    end
  end

  describe "stat/2" do
    test "returns file stat" do
      fs = InMemoryFS.new(%{"/file.txt" => "hello"})
      {:ok, stat} = InMemoryFS.stat(fs, "/file.txt")
      assert stat.is_file
      refute stat.is_directory
      assert stat.size == 5
    end

    test "returns directory stat" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/mydir")
      {:ok, stat} = InMemoryFS.stat(fs, "/mydir")
      assert stat.is_directory
      refute stat.is_file
      assert stat.size == 0
    end

    test "returns error for nonexistent" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.stat(fs, "/nonexistent")
    end

    test "follows symlinks" do
      fs = InMemoryFS.new(%{"/target.txt" => "hello"})
      {:ok, fs} = InMemoryFS.symlink(fs, "/target.txt", "/link")
      {:ok, stat} = InMemoryFS.stat(fs, "/link")
      assert stat.is_file
      refute stat.is_symbolic_link
    end
  end

  describe "lstat/2" do
    test "does not follow symlinks" do
      fs = InMemoryFS.new(%{"/target.txt" => "hello"})
      {:ok, fs} = InMemoryFS.symlink(fs, "/target.txt", "/link")
      {:ok, stat} = InMemoryFS.lstat(fs, "/link")
      assert stat.is_symbolic_link
      refute stat.is_file
    end
  end

  describe "chmod/3" do
    test "changes file mode" do
      fs = InMemoryFS.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFS.chmod(fs, "/file.txt", 0o755)
      {:ok, stat} = InMemoryFS.stat(fs, "/file.txt")
      assert stat.mode == 0o755
    end

    test "returns error for nonexistent" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.chmod(fs, "/nonexistent", 0o755)
    end
  end

  describe "symlink/3" do
    test "creates symbolic link" do
      fs = InMemoryFS.new(%{"/target.txt" => "content"})
      {:ok, fs} = InMemoryFS.symlink(fs, "/target.txt", "/link")
      assert {:ok, "content"} = InMemoryFS.read_file(fs, "/link")
    end

    test "returns error if link exists" do
      fs = InMemoryFS.new(%{"/file.txt" => "a"})
      assert {:error, :eexist} = InMemoryFS.symlink(fs, "/target", "/file.txt")
    end

    test "can create link to nonexistent target" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.symlink(fs, "/nonexistent", "/link")
      assert InMemoryFS.exists?(fs, "/link")
      assert {:error, :enoent} = InMemoryFS.read_file(fs, "/link")
    end
  end

  describe "readlink/2" do
    test "reads symlink target" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.symlink(fs, "/target/path", "/link")
      assert {:ok, "/target/path"} = InMemoryFS.readlink(fs, "/link")
    end

    test "returns error for non-symlink" do
      fs = InMemoryFS.new(%{"/file.txt" => "content"})
      assert {:error, :einval} = InMemoryFS.readlink(fs, "/file.txt")
    end

    test "returns error for nonexistent" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.readlink(fs, "/nonexistent")
    end
  end

  describe "link/3" do
    test "creates hard link" do
      fs = InMemoryFS.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFS.link(fs, "/file.txt", "/link")
      assert {:ok, "content"} = InMemoryFS.read_file(fs, "/link")
    end

    test "returns error for nonexistent source" do
      fs = InMemoryFS.new()
      assert {:error, :enoent} = InMemoryFS.link(fs, "/nonexistent", "/link")
    end

    test "returns error for directory source" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.mkdir(fs, "/dir")
      assert {:error, :eperm} = InMemoryFS.link(fs, "/dir", "/link")
    end

    test "returns error if dest exists" do
      fs = InMemoryFS.new(%{"/file.txt" => "a", "/existing" => "b"})
      assert {:error, :eexist} = InMemoryFS.link(fs, "/file.txt", "/existing")
    end
  end

  describe "get_all_paths/1" do
    test "returns all paths" do
      fs =
        InMemoryFS.new(%{
          "/file.txt" => "a",
          "/dir/nested.txt" => "b"
        })

      paths = InMemoryFS.get_all_paths(fs)
      assert "/" in paths
      assert "/file.txt" in paths
      assert "/dir" in paths
      assert "/dir/nested.txt" in paths
    end
  end

  describe "symlink loops" do
    test "detects symlink loops" do
      fs = InMemoryFS.new()
      {:ok, fs} = InMemoryFS.symlink(fs, "/link2", "/link1")
      {:ok, fs} = InMemoryFS.symlink(fs, "/link1", "/link2")
      assert {:error, :eloop} = InMemoryFS.read_file(fs, "/link1")
    end
  end
end
