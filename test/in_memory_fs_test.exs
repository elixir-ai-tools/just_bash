defmodule JustBash.Fs.InMemoryFsTest do
  use ExUnit.Case, async: true

  alias JustBash.Fs.InMemoryFs

  describe "new/1" do
    test "creates filesystem with root directory" do
      fs = InMemoryFs.new()
      assert InMemoryFs.exists?(fs, "/")
    end

    test "creates filesystem with initial files" do
      fs = InMemoryFs.new(%{"/home/user/file.txt" => "hello"})
      assert {:ok, "hello"} = InMemoryFs.read_file(fs, "/home/user/file.txt")
    end

    test "creates filesystem with extended file init" do
      fs = InMemoryFs.new(%{"/bin/script" => %{content: "#!/bin/bash", mode: 0o755}})
      assert {:ok, stat} = InMemoryFs.stat(fs, "/bin/script")
      assert stat.mode == 0o755
    end

    test "creates parent directories automatically" do
      fs = InMemoryFs.new(%{"/a/b/c/file.txt" => "content"})
      assert InMemoryFs.exists?(fs, "/a")
      assert InMemoryFs.exists?(fs, "/a/b")
      assert InMemoryFs.exists?(fs, "/a/b/c")
    end
  end

  describe "normalize_path/1" do
    test "handles root path" do
      assert InMemoryFs.normalize_path("/") == "/"
      assert InMemoryFs.normalize_path("") == "/"
    end

    test "removes trailing slashes" do
      assert InMemoryFs.normalize_path("/home/user/") == "/home/user"
    end

    test "ensures leading slash" do
      assert InMemoryFs.normalize_path("home/user") == "/home/user"
    end

    test "resolves . and .." do
      assert InMemoryFs.normalize_path("/home/user/../user/./file") == "/home/user/file"
      assert InMemoryFs.normalize_path("/home/../etc") == "/etc"
      assert InMemoryFs.normalize_path("/home/user/../../") == "/"
    end

    test "handles multiple slashes" do
      assert InMemoryFs.normalize_path("//home//user//") == "/home/user"
    end
  end

  describe "dirname/1" do
    test "returns parent directory" do
      assert InMemoryFs.dirname("/home/user/file.txt") == "/home/user"
      assert InMemoryFs.dirname("/home/user") == "/home"
    end

    test "returns root for top-level paths" do
      assert InMemoryFs.dirname("/file.txt") == "/"
      assert InMemoryFs.dirname("/") == "/"
    end
  end

  describe "basename/1" do
    test "returns file name" do
      assert InMemoryFs.basename("/home/user/file.txt") == "file.txt"
      assert InMemoryFs.basename("/home/user") == "user"
    end

    test "handles root" do
      assert InMemoryFs.basename("/") == "/"
    end
  end

  describe "resolve_path/2" do
    test "resolves absolute paths" do
      assert InMemoryFs.resolve_path("/home/user", "/etc/passwd") == "/etc/passwd"
    end

    test "resolves relative paths" do
      assert InMemoryFs.resolve_path("/home/user", "file.txt") == "/home/user/file.txt"
      assert InMemoryFs.resolve_path("/home/user", "subdir/file") == "/home/user/subdir/file"
    end

    test "handles root base" do
      assert InMemoryFs.resolve_path("/", "file.txt") == "/file.txt"
    end
  end

  describe "write_file/4 and read_file/2" do
    test "writes and reads file content" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.write_file(fs, "/test.txt", "hello world")
      assert {:ok, "hello world"} = InMemoryFs.read_file(fs, "/test.txt")
    end

    test "creates parent directories" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.write_file(fs, "/a/b/c/file.txt", "content")
      assert InMemoryFs.exists?(fs, "/a/b/c")
    end

    test "overwrites existing files" do
      fs = InMemoryFs.new(%{"/file.txt" => "old"})
      {:ok, fs} = InMemoryFs.write_file(fs, "/file.txt", "new")
      assert {:ok, "new"} = InMemoryFs.read_file(fs, "/file.txt")
    end

    test "read_file returns error for nonexistent file" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.read_file(fs, "/nonexistent")
    end

    test "read_file returns error for directory" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/mydir")
      assert {:error, :eisdir} = InMemoryFs.read_file(fs, "/mydir")
    end

    test "writes with custom mode" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.write_file(fs, "/script.sh", "#!/bin/bash", mode: 0o755)
      {:ok, stat} = InMemoryFs.stat(fs, "/script.sh")
      assert stat.mode == 0o755
    end
  end

  describe "append_file/3" do
    test "appends to existing file" do
      fs = InMemoryFs.new(%{"/file.txt" => "hello"})
      {:ok, fs} = InMemoryFs.append_file(fs, "/file.txt", " world")
      assert {:ok, "hello world"} = InMemoryFs.read_file(fs, "/file.txt")
    end

    test "creates file if it doesn't exist" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.append_file(fs, "/new.txt", "content")
      assert {:ok, "content"} = InMemoryFs.read_file(fs, "/new.txt")
    end
  end

  describe "mkdir/3" do
    test "creates directory" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/mydir")
      assert InMemoryFs.exists?(fs, "/mydir")
      {:ok, stat} = InMemoryFs.stat(fs, "/mydir")
      assert stat.is_directory
    end

    test "returns error if exists" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/mydir")
      assert {:error, :eexist} = InMemoryFs.mkdir(fs, "/mydir")
    end

    test "succeeds with recursive on existing dir" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/mydir")
      assert {:ok, _} = InMemoryFs.mkdir(fs, "/mydir", recursive: true)
    end

    test "returns error if parent doesn't exist" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.mkdir(fs, "/a/b/c")
    end

    test "creates parent directories with recursive" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/a/b/c", recursive: true)
      assert InMemoryFs.exists?(fs, "/a")
      assert InMemoryFs.exists?(fs, "/a/b")
      assert InMemoryFs.exists?(fs, "/a/b/c")
    end
  end

  describe "readdir/2" do
    test "lists directory contents" do
      fs =
        InMemoryFs.new(%{
          "/dir/file1.txt" => "a",
          "/dir/file2.txt" => "b",
          "/dir/subdir/file3.txt" => "c"
        })

      {:ok, entries} = InMemoryFs.readdir(fs, "/dir")
      assert Enum.sort(entries) == ["file1.txt", "file2.txt", "subdir"]
    end

    test "returns error for nonexistent dir" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.readdir(fs, "/nonexistent")
    end

    test "returns error for file" do
      fs = InMemoryFs.new(%{"/file.txt" => "content"})
      assert {:error, :enotdir} = InMemoryFs.readdir(fs, "/file.txt")
    end

    test "lists root directory" do
      fs = InMemoryFs.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFs.mkdir(fs, "/dir")
      {:ok, entries} = InMemoryFs.readdir(fs, "/")
      assert "file.txt" in entries
      assert "dir" in entries
    end
  end

  describe "rm/3" do
    test "removes file" do
      fs = InMemoryFs.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFs.rm(fs, "/file.txt")
      refute InMemoryFs.exists?(fs, "/file.txt")
    end

    test "removes empty directory" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/emptydir")
      {:ok, fs} = InMemoryFs.rm(fs, "/emptydir")
      refute InMemoryFs.exists?(fs, "/emptydir")
    end

    test "returns error for nonempty directory" do
      fs = InMemoryFs.new(%{"/dir/file.txt" => "content"})
      assert {:error, :enotempty} = InMemoryFs.rm(fs, "/dir")
    end

    test "removes directory recursively" do
      fs =
        InMemoryFs.new(%{
          "/dir/file.txt" => "a",
          "/dir/subdir/nested.txt" => "b"
        })

      {:ok, fs} = InMemoryFs.rm(fs, "/dir", recursive: true)
      refute InMemoryFs.exists?(fs, "/dir")
      refute InMemoryFs.exists?(fs, "/dir/file.txt")
      refute InMemoryFs.exists?(fs, "/dir/subdir")
    end

    test "returns error for nonexistent" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.rm(fs, "/nonexistent")
    end

    test "succeeds with force on nonexistent" do
      fs = InMemoryFs.new()
      assert {:ok, _} = InMemoryFs.rm(fs, "/nonexistent", force: true)
    end
  end

  describe "cp/4" do
    test "copies file" do
      fs = InMemoryFs.new(%{"/src.txt" => "content"})
      {:ok, fs} = InMemoryFs.cp(fs, "/src.txt", "/dest.txt")
      assert {:ok, "content"} = InMemoryFs.read_file(fs, "/dest.txt")
      assert {:ok, "content"} = InMemoryFs.read_file(fs, "/src.txt")
    end

    test "returns error for nonexistent source" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.cp(fs, "/nonexistent", "/dest")
    end

    test "returns error copying directory without recursive" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/srcdir")
      assert {:error, :eisdir} = InMemoryFs.cp(fs, "/srcdir", "/destdir")
    end

    test "copies directory recursively" do
      fs =
        InMemoryFs.new(%{
          "/srcdir/file.txt" => "a",
          "/srcdir/subdir/nested.txt" => "b"
        })

      {:ok, fs} = InMemoryFs.cp(fs, "/srcdir", "/destdir", recursive: true)
      assert {:ok, "a"} = InMemoryFs.read_file(fs, "/destdir/file.txt")
      assert {:ok, "b"} = InMemoryFs.read_file(fs, "/destdir/subdir/nested.txt")
    end
  end

  describe "mv/3" do
    test "moves file" do
      fs = InMemoryFs.new(%{"/src.txt" => "content"})
      {:ok, fs} = InMemoryFs.mv(fs, "/src.txt", "/dest.txt")
      assert {:ok, "content"} = InMemoryFs.read_file(fs, "/dest.txt")
      refute InMemoryFs.exists?(fs, "/src.txt")
    end

    test "moves directory" do
      fs = InMemoryFs.new(%{"/srcdir/file.txt" => "content"})
      {:ok, fs} = InMemoryFs.mv(fs, "/srcdir", "/destdir")
      assert {:ok, "content"} = InMemoryFs.read_file(fs, "/destdir/file.txt")
      refute InMemoryFs.exists?(fs, "/srcdir")
    end
  end

  describe "stat/2" do
    test "returns file stat" do
      fs = InMemoryFs.new(%{"/file.txt" => "hello"})
      {:ok, stat} = InMemoryFs.stat(fs, "/file.txt")
      assert stat.is_file
      refute stat.is_directory
      assert stat.size == 5
    end

    test "returns directory stat" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/mydir")
      {:ok, stat} = InMemoryFs.stat(fs, "/mydir")
      assert stat.is_directory
      refute stat.is_file
      assert stat.size == 0
    end

    test "returns error for nonexistent" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.stat(fs, "/nonexistent")
    end

    test "follows symlinks" do
      fs = InMemoryFs.new(%{"/target.txt" => "hello"})
      {:ok, fs} = InMemoryFs.symlink(fs, "/target.txt", "/link")
      {:ok, stat} = InMemoryFs.stat(fs, "/link")
      assert stat.is_file
      refute stat.is_symbolic_link
    end
  end

  describe "lstat/2" do
    test "does not follow symlinks" do
      fs = InMemoryFs.new(%{"/target.txt" => "hello"})
      {:ok, fs} = InMemoryFs.symlink(fs, "/target.txt", "/link")
      {:ok, stat} = InMemoryFs.lstat(fs, "/link")
      assert stat.is_symbolic_link
      refute stat.is_file
    end
  end

  describe "chmod/3" do
    test "changes file mode" do
      fs = InMemoryFs.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFs.chmod(fs, "/file.txt", 0o755)
      {:ok, stat} = InMemoryFs.stat(fs, "/file.txt")
      assert stat.mode == 0o755
    end

    test "returns error for nonexistent" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.chmod(fs, "/nonexistent", 0o755)
    end
  end

  describe "symlink/3" do
    test "creates symbolic link" do
      fs = InMemoryFs.new(%{"/target.txt" => "content"})
      {:ok, fs} = InMemoryFs.symlink(fs, "/target.txt", "/link")
      assert {:ok, "content"} = InMemoryFs.read_file(fs, "/link")
    end

    test "returns error if link exists" do
      fs = InMemoryFs.new(%{"/file.txt" => "a"})
      assert {:error, :eexist} = InMemoryFs.symlink(fs, "/target", "/file.txt")
    end

    test "can create link to nonexistent target" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.symlink(fs, "/nonexistent", "/link")
      assert InMemoryFs.exists?(fs, "/link")
      assert {:error, :enoent} = InMemoryFs.read_file(fs, "/link")
    end
  end

  describe "readlink/2" do
    test "reads symlink target" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.symlink(fs, "/target/path", "/link")
      assert {:ok, "/target/path"} = InMemoryFs.readlink(fs, "/link")
    end

    test "returns error for non-symlink" do
      fs = InMemoryFs.new(%{"/file.txt" => "content"})
      assert {:error, :einval} = InMemoryFs.readlink(fs, "/file.txt")
    end

    test "returns error for nonexistent" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.readlink(fs, "/nonexistent")
    end
  end

  describe "link/3" do
    test "creates hard link" do
      fs = InMemoryFs.new(%{"/file.txt" => "content"})
      {:ok, fs} = InMemoryFs.link(fs, "/file.txt", "/link")
      assert {:ok, "content"} = InMemoryFs.read_file(fs, "/link")
    end

    test "returns error for nonexistent source" do
      fs = InMemoryFs.new()
      assert {:error, :enoent} = InMemoryFs.link(fs, "/nonexistent", "/link")
    end

    test "returns error for directory source" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/dir")
      assert {:error, :eperm} = InMemoryFs.link(fs, "/dir", "/link")
    end

    test "returns error if dest exists" do
      fs = InMemoryFs.new(%{"/file.txt" => "a", "/existing" => "b"})
      assert {:error, :eexist} = InMemoryFs.link(fs, "/file.txt", "/existing")
    end
  end

  describe "get_all_paths/1" do
    test "returns all paths" do
      fs =
        InMemoryFs.new(%{
          "/file.txt" => "a",
          "/dir/nested.txt" => "b"
        })

      paths = InMemoryFs.get_all_paths(fs)
      assert "/" in paths
      assert "/file.txt" in paths
      assert "/dir" in paths
      assert "/dir/nested.txt" in paths
    end
  end

  describe "symlink loops" do
    test "detects symlink loops" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.symlink(fs, "/link2", "/link1")
      {:ok, fs} = InMemoryFs.symlink(fs, "/link1", "/link2")
      assert {:error, :eloop} = InMemoryFs.read_file(fs, "/link1")
    end
  end

  describe "content adapters" do
    alias JustBash.Fs.Content.FunctionContent
    alias JustBash.Fs.Content.S3Content

    test "new/1 accepts FunctionContent structs" do
      fc = FunctionContent.new(fn -> "generated content" end)
      fs = InMemoryFs.new(%{"/dynamic.txt" => fc})

      assert {:ok, "generated content"} = InMemoryFs.read_file(fs, "/dynamic.txt")
    end

    test "new/1 accepts bare anonymous functions" do
      fs = InMemoryFs.new(%{"/simple.txt" => fn -> "easy" end})

      assert {:ok, "easy"} = InMemoryFs.read_file(fs, "/simple.txt")
    end

    test "read_file resolves FunctionContent" do
      fc = FunctionContent.new({String, :upcase, ["hello"]})
      fs = InMemoryFs.new(%{"/upper.txt" => fc})

      assert {:ok, "HELLO"} = InMemoryFs.read_file(fs, "/upper.txt")
    end

    test "read_file returns error when function fails" do
      fc = FunctionContent.new(fn -> raise "boom" end)
      fs = InMemoryFs.new(%{"/error.txt" => fc})

      assert {:error, {:function_error, _}} = InMemoryFs.read_file(fs, "/error.txt")
    end

    test "stat returns size 0 for unmaterialized FunctionContent" do
      fc = FunctionContent.new(fn -> "hello world" end)
      fs = InMemoryFs.new(%{"/dynamic.txt" => fc})

      assert {:ok, stat} = InMemoryFs.stat(fs, "/dynamic.txt")
      assert stat.size == 0
    end

    test "stat returns correct size for materialized FunctionContent" do
      fc = FunctionContent.new(fn -> "hello world" end)
      {:ok, _content, materialized_fc} = FunctionContent.materialize(fc)

      fs = InMemoryFs.new(%{"/cached.txt" => materialized_fc})

      assert {:ok, stat} = InMemoryFs.stat(fs, "/cached.txt")
      assert stat.size == 11
    end

    test "append_file resolves FunctionContent before appending" do
      fc = FunctionContent.new(fn -> "start" end)
      fs = InMemoryFs.new(%{"/file.txt" => fc})

      {:ok, fs} = InMemoryFs.append_file(fs, "/file.txt", " end")

      assert {:ok, "start end"} = InMemoryFs.read_file(fs, "/file.txt")
    end

    test "append_file stores result as binary" do
      fc = FunctionContent.new(fn -> "start" end)
      fs = InMemoryFs.new(%{"/file.txt" => fc})

      {:ok, fs} = InMemoryFs.append_file(fs, "/file.txt", " end")

      # Second append should work on binary, not call function again
      {:ok, fs} = InMemoryFs.append_file(fs, "/file.txt", " more")

      assert {:ok, "start end more"} = InMemoryFs.read_file(fs, "/file.txt")
    end

    test "cp preserves FunctionContent adapter" do
      fc = FunctionContent.new(fn -> "dynamic" end)
      fs = InMemoryFs.new(%{"/source.txt" => fc})

      {:ok, fs} = InMemoryFs.cp(fs, "/source.txt", "/dest.txt")

      # Both files should resolve to the same content
      assert {:ok, "dynamic"} = InMemoryFs.read_file(fs, "/source.txt")
      assert {:ok, "dynamic"} = InMemoryFs.read_file(fs, "/dest.txt")
    end

    defmodule TestS3Client do
      @behaviour JustBash.Fs.Content.S3Content

      @impl true
      def get_object("test-bucket", "file.txt"), do: {:ok, "s3 content"}
      def get_object(_bucket, _key), do: {:error, :not_found}
    end

    test "read_file resolves S3Content" do
      s3 = S3Content.new(bucket: "test-bucket", key: "file.txt", client: TestS3Client)
      fs = InMemoryFs.new(%{"/remote.txt" => s3})

      assert {:ok, "s3 content"} = InMemoryFs.read_file(fs, "/remote.txt")
    end

    test "materialize/2 converts FunctionContent to binary" do
      fc = FunctionContent.new(fn -> "generated" end)
      fs = InMemoryFs.new(%{"/dynamic.txt" => fc})

      {:ok, fs} = InMemoryFs.materialize(fs, "/dynamic.txt")

      # Read the internal data to verify it's now binary
      entry = Map.get(fs.data, "/dynamic.txt")
      assert is_binary(entry.content)
      assert entry.content == "generated"
    end

    test "materialize/2 is no-op for binary content" do
      fs = InMemoryFs.new(%{"/normal.txt" => "hello"})

      {:ok, fs_after} = InMemoryFs.materialize(fs, "/normal.txt")

      assert fs == fs_after
    end

    test "materialize/2 returns error for non-existent file" do
      fs = InMemoryFs.new()

      assert {:error, :enoent} = InMemoryFs.materialize(fs, "/nonexistent.txt")
    end

    test "materialize/2 returns error for directory" do
      fs = InMemoryFs.new()
      {:ok, fs} = InMemoryFs.mkdir(fs, "/dir")

      assert {:error, :eisdir} = InMemoryFs.materialize(fs, "/dir")
    end

    test "materialize_all/1 resolves all lazy content" do
      fs =
        InMemoryFs.new(%{
          "/file1.txt" => fn -> "a" end,
          "/file2.txt" => "b",
          "/file3.txt" => FunctionContent.new(fn -> "c" end)
        })

      {:ok, fs} = InMemoryFs.materialize_all(fs)

      # All entries should now be binary
      assert is_binary(Map.get(fs.data, "/file1.txt").content)
      assert is_binary(Map.get(fs.data, "/file2.txt").content)
      assert is_binary(Map.get(fs.data, "/file3.txt").content)

      assert {:ok, "a"} = InMemoryFs.read_file(fs, "/file1.txt")
      assert {:ok, "b"} = InMemoryFs.read_file(fs, "/file2.txt")
      assert {:ok, "c"} = InMemoryFs.read_file(fs, "/file3.txt")
    end

    test "materialize_all/1 halts on first error" do
      fs =
        InMemoryFs.new(%{
          "/good.txt" => fn -> "ok" end,
          "/bad.txt" => FunctionContent.new(fn -> raise "error" end),
          "/also_good.txt" => fn -> "ok2" end
        })

      assert {:error, {:function_error, _}} = InMemoryFs.materialize_all(fs)
    end
  end
end
