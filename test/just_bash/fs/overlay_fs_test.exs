defmodule JustBash.Fs.OverlayFSTest do
  use ExUnit.Case, async: true

  alias JustBash.Fs
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Fs.OverlayFS
  alias JustBash.Fs.ReadOnlyFs

  describe "read-through to lower layer" do
    setup do
      lower = InMemoryFs.new(%{"/readme.txt" => "hello", "/src/main.ex" => "defmodule Main"})
      overlay = OverlayFS.new(lower: {InMemoryFs, lower})
      %{overlay: overlay, lower: lower}
    end

    test "exists? sees lower-layer files", %{overlay: s} do
      assert OverlayFS.exists?(s, "/readme.txt")
      assert OverlayFS.exists?(s, "/src/main.ex")
      refute OverlayFS.exists?(s, "/nope.txt")
    end

    test "read_file returns lower-layer content", %{overlay: s} do
      assert {:ok, "hello"} = OverlayFS.read_file(s, "/readme.txt")
    end

    test "stat returns lower-layer metadata", %{overlay: s} do
      {:ok, info} = OverlayFS.stat(s, "/readme.txt")
      assert info.is_file
      refute info.is_directory
    end

    test "readdir merges lower entries", %{overlay: s} do
      {:ok, entries} = OverlayFS.readdir(s, "/")
      assert "readme.txt" in entries
      assert "src" in entries
    end
  end

  describe "writes go to upper layer" do
    setup do
      lower = InMemoryFs.new(%{"/readme.txt" => "original"})
      overlay = OverlayFS.new(lower: {InMemoryFs, lower})
      %{overlay: overlay}
    end

    test "write_file creates in upper", %{overlay: s} do
      {:ok, s} = OverlayFS.write_file(s, "/new.txt", "fresh", [])
      assert {:ok, "fresh"} = OverlayFS.read_file(s, "/new.txt")
    end

    test "write_file shadows lower-layer file", %{overlay: s} do
      {:ok, s} = OverlayFS.write_file(s, "/readme.txt", "modified", [])
      assert {:ok, "modified"} = OverlayFS.read_file(s, "/readme.txt")
    end

    test "mkdir creates directory in upper", %{overlay: s} do
      {:ok, s} = OverlayFS.mkdir(s, "/newdir", recursive: true)
      assert OverlayFS.exists?(s, "/newdir")
      {:ok, info} = OverlayFS.stat(s, "/newdir")
      assert info.is_directory
    end

    test "append_file on upper-only file", %{overlay: s} do
      {:ok, s} = OverlayFS.write_file(s, "/log.txt", "line1\n", [])
      {:ok, s} = OverlayFS.append_file(s, "/log.txt", "line2\n")
      assert {:ok, "line1\nline2\n"} = OverlayFS.read_file(s, "/log.txt")
    end

    test "append_file COWs from lower", %{overlay: s} do
      {:ok, s} = OverlayFS.append_file(s, "/readme.txt", " world")
      assert {:ok, "original world"} = OverlayFS.read_file(s, "/readme.txt")
    end
  end

  describe "readdir merges both layers" do
    test "deduplicates entries present in both layers" do
      lower = InMemoryFs.new(%{"/a.txt" => "lower-a", "/b.txt" => "lower-b"})
      overlay = OverlayFS.new(lower: {InMemoryFs, lower})
      {:ok, overlay} = OverlayFS.write_file(overlay, "/a.txt", "upper-a", [])
      {:ok, overlay} = OverlayFS.write_file(overlay, "/c.txt", "upper-c", [])

      {:ok, entries} = OverlayFS.readdir(overlay, "/")
      assert entries == ["a.txt", "b.txt", "c.txt"]
    end

    test "returns :enoent for non-existent directory" do
      lower = InMemoryFs.new()
      overlay = OverlayFS.new(lower: {InMemoryFs, lower})
      assert {:error, :enoent} = OverlayFS.readdir(overlay, "/nope")
    end
  end

  describe "whiteouts (rm hides lower-layer entries)" do
    setup do
      lower =
        InMemoryFs.new(%{
          "/keep.txt" => "kept",
          "/remove.txt" => "gone",
          "/dir/a.txt" => "a",
          "/dir/b.txt" => "b"
        })

      overlay = OverlayFS.new(lower: {InMemoryFs, lower})
      %{overlay: overlay}
    end

    test "rm hides lower-layer file", %{overlay: s} do
      assert OverlayFS.exists?(s, "/remove.txt")
      {:ok, s} = OverlayFS.rm(s, "/remove.txt", [])
      refute OverlayFS.exists?(s, "/remove.txt")
      assert {:error, :enoent} = OverlayFS.read_file(s, "/remove.txt")
    end

    test "rm does not affect other files", %{overlay: s} do
      {:ok, s} = OverlayFS.rm(s, "/remove.txt", [])
      assert {:ok, "kept"} = OverlayFS.read_file(s, "/keep.txt")
    end

    test "rm -r on directory whiteouts it and children", %{overlay: s} do
      {:ok, s} = OverlayFS.rm(s, "/dir", recursive: true)
      refute OverlayFS.exists?(s, "/dir")
      refute OverlayFS.exists?(s, "/dir/a.txt")
      refute OverlayFS.exists?(s, "/dir/b.txt")
    end

    test "readdir excludes whiteout-ed entries", %{overlay: s} do
      {:ok, s} = OverlayFS.rm(s, "/remove.txt", [])
      {:ok, entries} = OverlayFS.readdir(s, "/")
      refute "remove.txt" in entries
      assert "keep.txt" in entries
    end

    test "write after rm un-deletes the path", %{overlay: s} do
      {:ok, s} = OverlayFS.rm(s, "/remove.txt", [])
      refute OverlayFS.exists?(s, "/remove.txt")

      {:ok, s} = OverlayFS.write_file(s, "/remove.txt", "resurrected", [])
      assert {:ok, "resurrected"} = OverlayFS.read_file(s, "/remove.txt")
    end

    test "rm on non-existent file returns :enoent", %{overlay: s} do
      assert {:error, :enoent} = OverlayFS.rm(s, "/nope.txt", [])
    end

    test "rm force on non-existent file returns :ok", %{overlay: s} do
      {:ok, _s} = OverlayFS.rm(s, "/nope.txt", force: true)
    end
  end

  describe "over a ReadOnlyFs lower layer" do
    test "writes succeed even though lower is read-only" do
      inner = InMemoryFs.new(%{"/base.txt" => "immutable"})
      ro = ReadOnlyFs.new(inner: {InMemoryFs, inner})
      overlay = OverlayFS.new(lower: {ReadOnlyFs, ro})

      assert {:ok, "immutable"} = OverlayFS.read_file(overlay, "/base.txt")

      {:ok, overlay} = OverlayFS.write_file(overlay, "/new.txt", "writable", [])
      assert {:ok, "writable"} = OverlayFS.read_file(overlay, "/new.txt")
      assert {:ok, "immutable"} = OverlayFS.read_file(overlay, "/base.txt")
    end
  end

  describe "chmod COW from lower" do
    test "chmod on lower-only file copies it up" do
      lower = InMemoryFs.new(%{"/script.sh" => "#!/bin/bash"})
      overlay = OverlayFS.new(lower: {InMemoryFs, lower})

      {:ok, overlay} = OverlayFS.chmod(overlay, "/script.sh", 0o755)
      {:ok, info} = OverlayFS.stat(overlay, "/script.sh")
      assert info.mode == 0o755
      assert {:ok, "#!/bin/bash"} = OverlayFS.read_file(overlay, "/script.sh")
    end
  end

  describe "mounted in VFS" do
    test "overlay mount is fully functional through Fs API" do
      lower = InMemoryFs.new(%{"/src/lib.ex" => "defmodule Lib"})
      overlay = OverlayFS.new(lower: {InMemoryFs, lower})

      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/project", OverlayFS, overlay)

      assert {:ok, "defmodule Lib"} = Fs.read_file(fs, "/project/src/lib.ex")

      {:ok, fs} = Fs.write_file(fs, "/project/notes.md", "# Notes")
      assert {:ok, "# Notes"} = Fs.read_file(fs, "/project/notes.md")
    end
  end

  describe "through JustBash" do
    test "bash commands work over an overlay" do
      lower =
        InMemoryFs.new(%{
          "/data/input.csv" => "a,b,c\n1,2,3\n",
          "/data/config.yml" => "key: value"
        })

      overlay = OverlayFS.new(lower: {InMemoryFs, lower})
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/project", OverlayFS, overlay)
      bash = JustBash.new(fs: fs)

      {result, bash} = JustBash.exec(bash, "cat /project/data/input.csv")
      assert result.exit_code == 0
      assert result.stdout == "a,b,c\n1,2,3\n"

      {result, bash} = JustBash.exec(bash, "echo 'new line' >> /project/data/input.csv")
      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "cat /project/data/input.csv")
      assert result.exit_code == 0
      assert result.stdout =~ "new line"

      {result, _bash} = JustBash.exec(bash, "ls /project/data")
      assert result.exit_code == 0
      assert result.stdout =~ "input.csv"
      assert result.stdout =~ "config.yml"
    end
  end
end
