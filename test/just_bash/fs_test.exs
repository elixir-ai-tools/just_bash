defmodule JustBash.FSTest do
  use ExUnit.Case, async: true

  alias JustBash.FS

  describe "new/1" do
    test "creates filesystem with root directory" do
      fs = FS.new()
      assert {true, _fs} = FS.exists?(fs, "/")
    end

    test "creates filesystem with initial files" do
      fs = FS.new(%{"/home/user/file.txt" => "hello"})
      assert {:ok, "hello", _fs} = FS.read_file(fs, "/home/user/file.txt")
    end

    test "creates filesystem with extended file init" do
      fs = FS.new(%{"/bin/script" => %{content: "#!/bin/bash", mode: 0o755}})
      assert {:ok, stat, _fs} = FS.stat(fs, "/bin/script")
      assert stat.mode == 0o755
    end

    test "creates parent directories automatically" do
      fs = FS.new(%{"/a/b/c/file.txt" => "content"})
      assert {true, fs} = FS.exists?(fs, "/a")
      assert {true, fs} = FS.exists?(fs, "/a/b")
      assert {true, _fs} = FS.exists?(fs, "/a/b/c")
    end

    test "is a %VFS{} mount table with the memory backend at /" do
      fs = FS.new()
      assert %VFS{} = fs
      assert [{"/", %JustBash.FS.Memory{}}] = VFS.mounts(fs)
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

    test "resolves .. relative to base" do
      assert FS.resolve_path("/home/user", "..") == "/home"
      assert FS.resolve_path("/home/user", "../other") == "/home/other"
    end

    test "handles root base" do
      assert FS.resolve_path("/", "file.txt") == "/file.txt"
    end
  end

  describe "write_file/4 and read_file/2" do
    test "writes and reads file content" do
      fs = FS.new()
      {:ok, fs} = FS.write_file(fs, "/test.txt", "hello world")
      assert {:ok, "hello world", _fs} = FS.read_file(fs, "/test.txt")
    end

    test "creates parent directories" do
      fs = FS.new()
      {:ok, fs} = FS.write_file(fs, "/a/b/c/file.txt", "content")
      assert {true, _fs} = FS.exists?(fs, "/a/b/c")
    end

    test "overwrites existing files" do
      fs = FS.new(%{"/file.txt" => "old"})
      {:ok, fs} = FS.write_file(fs, "/file.txt", "new")
      assert {:ok, "new", _fs} = FS.read_file(fs, "/file.txt")
    end

    test "read_file returns error for nonexistent file" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.read_file(fs, "/nonexistent")
    end

    test "read_file returns error for directory" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/mydir")
      assert {:error, %VFS.Error{kind: :eisdir}} = FS.read_file(fs, "/mydir")
    end

    test "writes with custom mode" do
      fs = FS.new()
      {:ok, fs} = FS.write_file(fs, "/script.sh", "#!/bin/bash", mode: 0o755)
      {:ok, stat, _fs} = FS.stat(fs, "/script.sh")
      assert stat.mode == 0o755
    end

    test "writes through a symlink to the target, keeping the link" do
      fs = FS.new(%{"/target.txt" => "old content"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, fs} = FS.write_file(fs, "/link", "new")

      assert {:ok, "new", fs} = FS.read_file(fs, "/target.txt")
      assert {:ok, %VFS.Stat{type: :symlink}, _fs} = FS.lstat(fs, "/link")
    end

    test "writing to a dangling symlink creates the target" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/missing.txt", "/link")
      {:ok, fs} = FS.write_file(fs, "/link", "created")

      assert {:ok, "created", fs} = FS.read_file(fs, "/missing.txt")
      assert {:ok, %VFS.Stat{type: :symlink}, _fs} = FS.lstat(fs, "/link")
    end

    test "writing through a symlink loop fails with :eloop" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/l2", "/l1")
      {:ok, fs} = FS.symlink(fs, "/l1", "/l2")

      assert {:error, %VFS.Error{kind: :eloop}} = FS.write_file(fs, "/l1", "x")
    end
  end

  describe "append_file/3" do
    test "appends to existing file" do
      fs = FS.new(%{"/file.txt" => "hello"})
      {:ok, fs} = FS.append_file(fs, "/file.txt", " world")
      assert {:ok, "hello world", _fs} = FS.read_file(fs, "/file.txt")
    end

    test "creates file if it doesn't exist" do
      fs = FS.new()
      {:ok, fs} = FS.append_file(fs, "/new.txt", "content")
      assert {:ok, "content", _fs} = FS.read_file(fs, "/new.txt")
    end

    test "preserves the file's mode" do
      fs = FS.new(%{"/script.sh" => %{content: "#!/bin/bash\n", mode: 0o755}})
      {:ok, fs} = FS.append_file(fs, "/script.sh", "echo hi\n")
      {:ok, stat, _fs} = FS.stat(fs, "/script.sh")
      assert stat.mode == 0o755
    end

    test "appends through a symlink to the target, keeping the link" do
      fs = FS.new(%{"/target.txt" => "hello"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, fs} = FS.append_file(fs, "/link", " world")

      assert {:ok, "hello world", fs} = FS.read_file(fs, "/target.txt")
      assert {:ok, %VFS.Stat{type: :symlink}, _fs} = FS.lstat(fs, "/link")
    end

    test "appending to a dangling symlink creates the target" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/missing.txt", "/link")
      {:ok, fs} = FS.append_file(fs, "/link", "created")

      assert {:ok, "created", fs} = FS.read_file(fs, "/missing.txt")
      assert {:ok, %VFS.Stat{type: :symlink}, _fs} = FS.lstat(fs, "/link")
    end

    test "appending through a symlink loop fails with :eloop" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/l2", "/l1")
      {:ok, fs} = FS.symlink(fs, "/l1", "/l2")

      assert {:error, %VFS.Error{kind: :eloop}} = FS.append_file(fs, "/l1", "x")
    end
  end

  describe "mkdir/3" do
    test "creates directory" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/mydir")
      assert {true, fs} = FS.exists?(fs, "/mydir")
      {:ok, stat, _fs} = FS.stat(fs, "/mydir")
      assert stat.type == :directory
    end

    test "returns error if exists" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/mydir")
      assert {:error, %VFS.Error{kind: :eexist}} = FS.mkdir(fs, "/mydir")
    end

    test "succeeds with parents on existing dir" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/mydir")
      assert {:ok, _} = FS.mkdir(fs, "/mydir", parents: true)
    end

    test "returns error if parent doesn't exist" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.mkdir(fs, "/a/b/c")
    end

    test "creates parent directories with parents: true" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/a/b/c", parents: true)
      assert {true, fs} = FS.exists?(fs, "/a")
      assert {true, fs} = FS.exists?(fs, "/a/b")
      assert {true, _fs} = FS.exists?(fs, "/a/b/c")
    end
  end

  describe "readdir/2" do
    test "lists directory contents" do
      fs =
        FS.new(%{
          "/dir/file1.txt" => "a",
          "/dir/file2.txt" => "b",
          "/dir/subdir/file3.txt" => "c"
        })

      {:ok, entries, _fs} = FS.readdir(fs, "/dir")
      assert Enum.sort(entries) == ["file1.txt", "file2.txt", "subdir"]
    end

    test "returns error for nonexistent dir" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.readdir(fs, "/nonexistent")
    end

    test "returns error for file" do
      fs = FS.new(%{"/file.txt" => "content"})
      assert {:error, %VFS.Error{kind: :enotdir}} = FS.readdir(fs, "/file.txt")
    end

    test "lists root directory" do
      fs = FS.new(%{"/file.txt" => "content"})
      {:ok, fs} = FS.mkdir(fs, "/dir")
      {:ok, entries, _fs} = FS.readdir(fs, "/")
      assert "file.txt" in entries
      assert "dir" in entries
    end
  end

  describe "rm/3" do
    test "removes file" do
      fs = FS.new(%{"/file.txt" => "content"})
      {:ok, fs} = FS.rm(fs, "/file.txt")
      assert {false, _fs} = FS.exists?(fs, "/file.txt")
    end

    test "removes empty directory" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/emptydir")
      {:ok, fs} = FS.rm(fs, "/emptydir")
      assert {false, _fs} = FS.exists?(fs, "/emptydir")
    end

    test "returns error for nonempty directory" do
      fs = FS.new(%{"/dir/file.txt" => "content"})
      assert {:error, %VFS.Error{kind: :enotempty}} = FS.rm(fs, "/dir")
    end

    test "removes directory recursively" do
      fs =
        FS.new(%{
          "/dir/file.txt" => "a",
          "/dir/subdir/nested.txt" => "b"
        })

      {:ok, fs} = FS.rm(fs, "/dir", recursive: true)
      assert {false, fs} = FS.exists?(fs, "/dir")
      assert {false, fs} = FS.exists?(fs, "/dir/file.txt")
      assert {false, _fs} = FS.exists?(fs, "/dir/subdir")
    end

    test "returns error for nonexistent" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.rm(fs, "/nonexistent")
    end
  end

  describe "cp/4" do
    test "copies file" do
      fs = FS.new(%{"/src.txt" => "content"})
      {:ok, fs} = FS.cp(fs, "/src.txt", "/dest.txt")
      assert {:ok, "content", fs} = FS.read_file(fs, "/dest.txt")
      assert {:ok, "content", _fs} = FS.read_file(fs, "/src.txt")
    end

    test "preserves mode and mtime" do
      mtime = ~U[2024-01-02 03:04:05Z]
      fs = FS.new(%{"/src.sh" => %{content: "#!/bin/bash", mode: 0o755, mtime: mtime}})
      {:ok, fs} = FS.cp(fs, "/src.sh", "/dest.sh")
      {:ok, stat, _fs} = FS.stat(fs, "/dest.sh")
      assert stat.mode == 0o755
      assert stat.mtime == mtime
    end

    test "writes through a destination symlink (unlike mv, which replaces it)" do
      fs = FS.new(%{"/src.txt" => "SRC", "/target.txt" => "TARGET"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, fs} = FS.cp(fs, "/src.txt", "/link")

      assert {:ok, "SRC", fs} = FS.read_file(fs, "/target.txt")
      assert {:ok, %VFS.Stat{type: :symlink}, _fs} = FS.lstat(fs, "/link")
    end

    test "copies symlinks as symlinks" do
      fs = FS.new(%{"/target.txt" => "content"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, fs} = FS.cp(fs, "/link", "/link2")
      assert {:ok, "/target.txt", _fs} = FS.readlink(fs, "/link2")
    end

    test "returns error for nonexistent source" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.cp(fs, "/nonexistent", "/dest")
    end

    test "returns error copying directory without recursive" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/srcdir")
      assert {:error, %VFS.Error{kind: :eisdir}} = FS.cp(fs, "/srcdir", "/destdir")
    end

    test "copies directory recursively" do
      fs =
        FS.new(%{
          "/srcdir/file.txt" => "a",
          "/srcdir/subdir/nested.txt" => "b"
        })

      {:ok, fs} = FS.cp(fs, "/srcdir", "/destdir", recursive: true)
      assert {:ok, "a", fs} = FS.read_file(fs, "/destdir/file.txt")
      assert {:ok, "b", _fs} = FS.read_file(fs, "/destdir/subdir/nested.txt")
    end
  end

  describe "mv/3" do
    test "moves file" do
      fs = FS.new(%{"/src.txt" => "content"})
      {:ok, fs} = FS.mv(fs, "/src.txt", "/dest.txt")
      assert {:ok, "content", fs} = FS.read_file(fs, "/dest.txt")
      assert {false, _fs} = FS.exists?(fs, "/src.txt")
    end

    test "moves directory" do
      fs = FS.new(%{"/srcdir/file.txt" => "content"})
      {:ok, fs} = FS.mv(fs, "/srcdir", "/destdir")
      assert {:ok, "content", fs} = FS.read_file(fs, "/destdir/file.txt")
      assert {false, _fs} = FS.exists?(fs, "/srcdir")
    end

    test "replaces a destination symlink instead of writing through it" do
      fs = FS.new(%{"/src.txt" => "SRC", "/target.txt" => "TARGET"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, fs} = FS.mv(fs, "/src.txt", "/link")

      # rename(2) semantics: the destination name itself is replaced...
      assert {:ok, %VFS.Stat{type: :regular}, fs} = FS.lstat(fs, "/link")
      assert {:ok, "SRC", fs} = FS.read_file(fs, "/link")
      # ...and the old target is untouched
      assert {:ok, "TARGET", fs} = FS.read_file(fs, "/target.txt")
      assert {false, _fs} = FS.exists?(fs, "/src.txt")
    end

    test "moving onto itself is a no-op" do
      fs = FS.new(%{"/file.txt" => "content"})
      {:ok, fs} = FS.mv(fs, "/file.txt", "/file.txt")
      assert {:ok, "content", _fs} = FS.read_file(fs, "/file.txt")
    end
  end

  describe "stat/2" do
    test "returns file stat" do
      fs = FS.new(%{"/file.txt" => "hello"})
      {:ok, stat, _fs} = FS.stat(fs, "/file.txt")
      assert stat.type == :regular
      assert stat.size == 5
    end

    test "returns directory stat" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/mydir")
      {:ok, stat, _fs} = FS.stat(fs, "/mydir")
      assert stat.type == :directory
      assert stat.size == 0
    end

    test "returns error for nonexistent" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.stat(fs, "/nonexistent")
    end

    test "follows symlinks" do
      fs = FS.new(%{"/target.txt" => "hello"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, stat, _fs} = FS.stat(fs, "/link")
      assert stat.type == :regular
    end
  end

  describe "lstat/2" do
    test "does not follow symlinks" do
      fs = FS.new(%{"/target.txt" => "hello"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, stat, _fs} = FS.lstat(fs, "/link")
      assert stat.type == :symlink
    end

    test "matches stat for regular files" do
      fs = FS.new(%{"/file.txt" => "hello"})
      {:ok, stat, _fs} = FS.lstat(fs, "/file.txt")
      assert stat.type == :regular
      assert stat.size == 5
    end
  end

  describe "chmod/3" do
    test "changes file mode" do
      fs = FS.new(%{"/file.txt" => "content"})
      {:ok, fs} = FS.chmod(fs, "/file.txt", 0o755)
      {:ok, stat, _fs} = FS.stat(fs, "/file.txt")
      assert stat.mode == 0o755
    end

    test "returns error for nonexistent" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.chmod(fs, "/nonexistent", 0o755)
    end

    test "follows symlinks to the target" do
      fs = FS.new(%{"/target.txt" => "content"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      {:ok, fs} = FS.chmod(fs, "/link", 0o755)

      {:ok, stat, fs} = FS.stat(fs, "/target.txt")
      assert stat.mode == 0o755

      # the link entry itself keeps its conventional 0o777
      {:ok, link_stat, _fs} = FS.lstat(fs, "/link")
      assert link_stat.mode == 0o777
    end

    test "returns error for a dangling symlink" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/missing", "/link")
      assert {:error, %VFS.Error{kind: :enoent}} = FS.chmod(fs, "/link", 0o755)
    end

    test "fails with :eloop on a symlink loop" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/l2", "/l1")
      {:ok, fs} = FS.symlink(fs, "/l1", "/l2")

      assert {:error, %VFS.Error{kind: :eloop}} = FS.chmod(fs, "/l1", 0o755)
    end
  end

  describe "symlink/3" do
    test "creates symbolic link" do
      fs = FS.new(%{"/target.txt" => "content"})
      {:ok, fs} = FS.symlink(fs, "/target.txt", "/link")
      assert {:ok, "content", _fs} = FS.read_file(fs, "/link")
    end

    test "resolves relative targets against the link's directory" do
      fs = FS.new(%{"/dir/target.txt" => "content"})
      {:ok, fs} = FS.symlink(fs, "target.txt", "/dir/link")
      assert {:ok, "content", _fs} = FS.read_file(fs, "/dir/link")
    end

    test "returns error if link exists" do
      fs = FS.new(%{"/file.txt" => "a"})
      assert {:error, %VFS.Error{kind: :eexist}} = FS.symlink(fs, "/target", "/file.txt")
    end

    test "can create link to nonexistent target" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/nonexistent", "/link")
      assert {true, fs} = FS.exists?(fs, "/link")
      assert {:error, %VFS.Error{kind: :enoent}} = FS.read_file(fs, "/link")
    end
  end

  describe "readlink/2" do
    test "reads symlink target" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/target/path", "/link")
      assert {:ok, "/target/path", _fs} = FS.readlink(fs, "/link")
    end

    test "returns error for non-symlink" do
      fs = FS.new(%{"/file.txt" => "content"})
      assert {:error, %VFS.Error{kind: :einval}} = FS.readlink(fs, "/file.txt")
    end

    test "returns error for nonexistent" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.readlink(fs, "/nonexistent")
    end
  end

  describe "link/3" do
    test "creates hard link" do
      fs = FS.new(%{"/file.txt" => "content"})
      {:ok, fs} = FS.link(fs, "/file.txt", "/link")
      assert {:ok, "content", _fs} = FS.read_file(fs, "/link")
    end

    test "returns error for nonexistent source" do
      fs = FS.new()
      assert {:error, %VFS.Error{kind: :enoent}} = FS.link(fs, "/nonexistent", "/link")
    end

    test "returns error for directory source" do
      fs = FS.new()
      {:ok, fs} = FS.mkdir(fs, "/dir")
      assert {:error, %VFS.Error{kind: :eacces}} = FS.link(fs, "/dir", "/link")
    end

    test "returns error if dest exists" do
      fs = FS.new(%{"/file.txt" => "a", "/existing" => "b"})
      assert {:error, %VFS.Error{kind: :eexist}} = FS.link(fs, "/file.txt", "/existing")
    end
  end

  describe "symlink loops" do
    test "detects symlink loops" do
      fs = FS.new()
      {:ok, fs} = FS.symlink(fs, "/link2", "/link1")
      {:ok, fs} = FS.symlink(fs, "/link1", "/link2")
      assert {:error, %VFS.Error{kind: :eloop}} = FS.read_file(fs, "/link1")
    end
  end

  describe "walk/3" do
    test "walks the tree" do
      fs = FS.new(%{"/a.txt" => "1", "/dir/b.txt" => "2"})

      paths = fs |> FS.walk("/") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert paths == ["/a.txt", "/dir/b.txt"]
    end
  end

  describe "legacy option guards" do
    test "mkdir rejects the 0.3 :recursive option loudly" do
      fs = FS.new()

      assert_raise ArgumentError, ~r/parents: true/, fn ->
        FS.mkdir(fs, "/a/b", recursive: true)
      end
    end

    test "rm rejects the 0.3 :force option loudly" do
      fs = FS.new()

      assert_raise ArgumentError, ~r/UPGRADING/, fn ->
        FS.rm(fs, "/nope", force: true)
      end
    end
  end

  describe "strerror/1" do
    test "maps kinds to conventional messages" do
      assert FS.strerror(:enoent) == "No such file or directory"
      assert FS.strerror(:enotempty) == "Directory not empty"
      assert FS.strerror(:erofs) == "Read-only file system"
      assert FS.strerror(VFS.Error.new(:eisdir, path: "/x")) == "Is a directory"
    end
  end

  describe "mount table integration" do
    test "reads and writes route to a second mount" do
      fs = FS.new()
      fs = VFS.mount(fs, "/mnt", VFS.Memory.new(%{"/data.txt" => "mounted"}))

      assert {:ok, "mounted", fs} = FS.read_file(fs, "/mnt/data.txt")
      {:ok, fs} = FS.write_file(fs, "/mnt/new.txt", "written")
      assert {:ok, "written", fs} = FS.read_file(fs, "/mnt/new.txt")

      # the root backend is untouched
      assert {false, _fs} = FS.exists?(fs, "/data.txt")
    end

    test "cp composes across mounts" do
      fs = FS.new(%{"/home/user/src.txt" => "cross"})
      fs = VFS.mount(fs, "/mnt", VFS.Memory.new())

      {:ok, fs} = FS.cp(fs, "/home/user/src.txt", "/mnt/dest.txt")
      assert {:ok, "cross", _fs} = FS.read_file(fs, "/mnt/dest.txt")
    end

    test "POSIX extras degrade gracefully on backends without them" do
      fs = FS.new()
      fs = VFS.mount(fs, "/mnt", VFS.Memory.new(%{"/data.txt" => "x"}))

      # lstat falls back to stat
      assert {:ok, %VFS.Stat{type: :regular}, fs} = FS.lstat(fs, "/mnt/data.txt")

      # symlink/link are unsupported
      assert {:error, %VFS.Error{kind: :enotsup}} = FS.symlink(fs, "/t", "/mnt/link")
      assert {:error, %VFS.Error{kind: :enotsup}} = FS.link(fs, "/mnt/data.txt", "/mnt/hard")

      # readlink: nothing is a symlink
      assert {:error, %VFS.Error{kind: :einval}} = FS.readlink(fs, "/mnt/data.txt")
      assert {:error, %VFS.Error{kind: :enoent}} = FS.readlink(fs, "/mnt/nope")

      # chmod is a validated no-op
      assert {:ok, fs} = FS.chmod(fs, "/mnt/data.txt", 0o600)
      assert {:error, %VFS.Error{kind: :enoent}} = FS.chmod(fs, "/mnt/nope", 0o600)

      # append composes read + write
      {:ok, fs} = FS.append_file(fs, "/mnt/data.txt", "y")
      assert {:ok, "xy", _fs} = FS.read_file(fs, "/mnt/data.txt")
    end

    test "POSIX extras route through the mount table to the memory backend" do
      fs = FS.new()
      fs = VFS.mount(fs, "/scratch", JustBash.FS.Memory.new(%{"/t.txt" => "hi"}))

      {:ok, fs} = FS.symlink(fs, "t.txt", "/scratch/link")
      assert {:ok, "hi", fs} = FS.read_file(fs, "/scratch/link")
      assert {:ok, %VFS.Stat{type: :symlink}, fs} = FS.lstat(fs, "/scratch/link")
      assert {:ok, "t.txt", _fs} = FS.readlink(fs, "/scratch/link")
    end

    test "error paths are reported in the caller's namespace" do
      fs = FS.new()
      fs = VFS.mount(fs, "/mnt", JustBash.FS.Memory.new())

      assert {:error, %VFS.Error{kind: :enoent, path: "/mnt/missing", mount: "/mnt"}} =
               FS.readlink(fs, "/mnt/missing")
    end

    test "hard links across mounts are refused with :exdev" do
      fs = FS.new(%{"/home/user/f.txt" => "x"})
      fs = VFS.mount(fs, "/scratch", JustBash.FS.Memory.new())

      assert {:error, %VFS.Error{kind: :exdev}} =
               FS.link(fs, "/home/user/f.txt", "/scratch/hard")
    end

    test "link reports the new path when it resolves to no mount" do
      # a sparse table: only /a is mounted, so /b/g resolves to no mount
      fs = VFS.new() |> VFS.mount("/a", JustBash.FS.Memory.new(%{"/f.txt" => "x"}))

      assert {:error, %VFS.Error{kind: :enoent, path: "/b/g"}} =
               FS.link(fs, "/a/f.txt", "/b/g")
    end
  end
end
