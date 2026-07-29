defmodule JustBash.NotADirectoryTest do
  @moduledoc """
  Regression tests for issue #53: a write through a path component that is
  a regular file used to succeed, storing an entry that `FS.walk/3` could
  never reach.

  POSIX path resolution says every non-final component must be a
  directory; anything else is `ENOTDIR`. Enforcing that at the filesystem
  layer is what makes the unreachable state impossible by construction,
  so most of these tests poke `JustBash.FS` directly and the shell tests
  only assert the bash-shaped rendering of the error.
  """
  use ExUnit.Case, async: true

  alias JustBash.FS
  alias JustBash.FS.Memory

  # /m/j is a regular file, so nothing may be created under it.
  defp fs_with_file_parent, do: FS.new(%{"/m/j" => "parent\n"})

  defp bash_with_file_parent(files \\ %{}) do
    JustBash.new(files: Map.merge(%{"/m/j" => "parent\n"}, files))
  end

  defp walked(fs, root) do
    fs |> FS.walk(root, include_dirs: true) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  describe "FS.write_file/4 through a regular file" do
    test "returns :enotdir when the parent component is a regular file" do
      assert {:error, %VFS.Error{kind: :enotdir}} =
               FS.write_file(fs_with_file_parent(), "/m/j/a.md", "hi\n")
    end

    test "returns :enotdir when a deeper ancestor is a regular file" do
      assert {:error, %VFS.Error{kind: :enotdir}} =
               FS.write_file(fs_with_file_parent(), "/m/j/2026/a.md", "hi\n")
    end

    test "the backend names the offending component, the mount table the requested path" do
      backend = Memory.new(%{"/m/j" => "parent\n"})

      assert {:error, %VFS.Error{kind: :enotdir, path: "/m/j"}} =
               Memory.write_file(backend, "/m/j/2026/a.md", "hi\n")

      # vfs rewrites error paths into the caller's namespace, which is also
      # the path bash names in `bash: /m/j/2026/a.md: Not a directory`.
      assert {:error, %VFS.Error{kind: :enotdir, path: "/m/j/2026/a.md"}} =
               FS.write_file(fs_with_file_parent(), "/m/j/2026/a.md", "hi\n")
    end

    test "leaves the store untouched" do
      fs = fs_with_file_parent()
      assert {:error, _} = FS.write_file(fs, "/m/j/2026/a.md", "hi\n")
      assert {:error, %VFS.Error{}} = FS.read_file(fs, "/m/j/2026/a.md")
      assert walked(fs, "/m") == ["/m", "/m/j"]
    end

    test "still creates missing intermediate directories under a real directory" do
      assert {:ok, fs} = FS.write_file(FS.new(), "/m/d/2026/a.md", "hi\n")
      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/m/d/2026/a.md")
      assert "/m/d/2026" in walked(fs, "/m")
    end

    test "resolves a symlinked intermediate component to its target directory" do
      {:ok, fs} = FS.mkdir(FS.new(), "/real", parents: true)
      {:ok, fs} = FS.symlink(fs, "/real", "/link")

      assert {:ok, fs} = FS.write_file(fs, "/link/sub/a.md", "hi\n")
      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/real/sub/a.md")
      assert "/real/sub/a.md" in walked(fs, "/real")
    end

    test "returns :enotdir when an intermediate symlink points at a regular file" do
      {:ok, fs} = FS.write_file(FS.new(), "/file", "x")
      {:ok, fs} = FS.symlink(fs, "/file", "/link")

      assert {:error, %VFS.Error{kind: :enotdir}} = FS.write_file(fs, "/link/a.md", "hi\n")
    end
  end

  describe "other path-creating FS operations through a regular file" do
    test "append_file/3 returns :enotdir" do
      assert {:error, %VFS.Error{kind: :enotdir}} =
               FS.append_file(fs_with_file_parent(), "/m/j/a.md", "hi\n")

      assert {:error, %VFS.Error{kind: :enotdir}} =
               FS.append_file(fs_with_file_parent(), "/m/j/2026/a.md", "hi\n")
    end

    test "mkdir/3 with parents: true returns :enotdir" do
      assert {:error, %VFS.Error{kind: :enotdir}} =
               FS.mkdir(fs_with_file_parent(), "/m/j/2026", parents: true)
    end

    test "mkdir/3 without parents returns :enotdir" do
      assert {:error, %VFS.Error{kind: :enotdir}} =
               FS.mkdir(fs_with_file_parent(), "/m/j/2026")
    end

    test "mkdir/3 on the regular file itself still reports :eexist" do
      assert {:error, %VFS.Error{kind: :eexist}} = FS.mkdir(fs_with_file_parent(), "/m/j")

      assert {:error, %VFS.Error{kind: :eexist}} =
               FS.mkdir(fs_with_file_parent(), "/m/j", parents: true)
    end

    test "symlink/3 returns :enotdir" do
      assert {:error, %VFS.Error{kind: :enotdir}} =
               FS.symlink(fs_with_file_parent(), "/m", "/m/j/link")
    end

    test "link/3 returns :enotdir" do
      {:ok, fs} = FS.write_file(fs_with_file_parent(), "/src.txt", "x")

      assert {:error, %VFS.Error{kind: :enotdir}} = FS.link(fs, "/src.txt", "/m/j/hard")
    end

    test "cp/4 returns :enotdir" do
      {:ok, fs} = FS.write_file(fs_with_file_parent(), "/src.txt", "x")

      assert {:error, %VFS.Error{kind: :enotdir}} = FS.cp(fs, "/src.txt", "/m/j/a.md")
    end

    test "mv/3 returns :enotdir and keeps the source" do
      {:ok, fs} = FS.write_file(fs_with_file_parent(), "/src.txt", "x")

      assert {:error, %VFS.Error{kind: :enotdir}} = FS.mv(fs, "/src.txt", "/m/j/a.md")
      assert {:ok, "x", _fs} = FS.read_file(fs, "/src.txt")
    end
  end

  describe "shell redirections through a regular file" do
    test "> reports Not a directory when the parent is a regular file" do
      {result, bash} = JustBash.exec(bash_with_file_parent(), "echo hi > /m/j/a.md")

      assert result.exit_code == 1
      assert result.stderr == "bash: /m/j/a.md: Not a directory\n"
      assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, "/m/j/a.md")
    end

    test "> reports Not a directory for a deeper path and stores nothing" do
      {result, bash} = JustBash.exec(bash_with_file_parent(), "echo hi > /m/j/2026/a.md")

      assert result.exit_code == 1
      assert result.stderr == "bash: /m/j/2026/a.md: Not a directory\n"
      assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, "/m/j/2026/a.md")
      assert walked(bash.fs, "/m") == ["/m", "/m/j"]
    end

    test ">> reports Not a directory" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "echo hi >> /m/j/2026/a.md")

      assert result.exit_code == 1
      assert result.stderr == "bash: /m/j/2026/a.md: Not a directory\n"
    end

    test "2> reports Not a directory" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "ls /nope 2> /m/j/err.log")

      assert result.exit_code == 1
      assert result.stderr =~ "bash: /m/j/err.log: Not a directory\n"
    end

    test "&> reports Not a directory" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "echo hi &> /m/j/a.md")

      assert result.exit_code == 1
      assert result.stderr == "bash: /m/j/a.md: Not a directory\n"
    end
  end

  describe "commands that create paths through a regular file" do
    test "mkdir -p reports Not a directory" do
      {result, bash} = JustBash.exec(bash_with_file_parent(), "mkdir -p /m/j/2026")

      assert result.exit_code == 1
      assert result.stderr == "mkdir: cannot create directory '/m/j/2026': Not a directory\n"
      assert walked(bash.fs, "/m") == ["/m", "/m/j"]
    end

    test "mkdir reports Not a directory" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "mkdir /m/j/2026")

      assert result.exit_code == 1
      assert result.stderr == "mkdir: cannot create directory '/m/j/2026': Not a directory\n"
    end

    test "mkdir -p on the regular file itself reports File exists" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "mkdir -p /m/j")

      assert result.exit_code == 1
      assert result.stderr == "mkdir: cannot create directory '/m/j': File exists\n"
    end

    test "mkdir -p on an existing directory still succeeds" do
      {result, _bash} = JustBash.exec(JustBash.new(), "mkdir -p /m/d && mkdir -p /m/d")

      assert result.exit_code == 0
      assert result.stderr == ""
    end

    test "touch reports Not a directory" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "touch /m/j/a.md")

      assert result.exit_code == 1
      assert result.stderr == "touch: cannot touch '/m/j/a.md': Not a directory\n"
    end

    test "cp reports Not a directory" do
      bash = bash_with_file_parent(%{"/src.txt" => "x\n"})
      {result, bash} = JustBash.exec(bash, "cp /src.txt /m/j/a.md")

      assert result.exit_code == 1

      assert result.stderr ==
               "cp: cannot create regular file '/m/j/a.md': Not a directory\n"

      assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, "/m/j/a.md")
    end

    test "mv reports Not a directory and keeps the source" do
      bash = bash_with_file_parent(%{"/src.txt" => "x\n"})
      {result, bash} = JustBash.exec(bash, "mv /src.txt /m/j/a.md")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot move '/src.txt' to '/m/j/a.md': Not a directory\n"
      assert {:ok, "x\n", _fs} = FS.read_file(bash.fs, "/src.txt")
    end

    test "tee reports Not a directory but still passes stdin through" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "echo hi | tee /m/j/a.md")

      assert result.exit_code == 1
      assert result.stdout == "hi\n"
      assert result.stderr == "tee: /m/j/a.md: Not a directory\n"
    end

    test "ln -s reports Not a directory" do
      bash = bash_with_file_parent(%{"/src.txt" => "x\n"})
      {result, _bash} = JustBash.exec(bash, "ln -s /src.txt /m/j/link")

      assert result.exit_code == 1

      assert result.stderr ==
               "ln: failed to create symbolic link '/m/j/link': Not a directory\n"
    end
  end

  describe "store reachability" do
    test "everything the shell writes is reachable from walk/3" do
      bash = bash_with_file_parent()

      {_result, bash} =
        JustBash.exec(bash, """
        echo hi > /m/j/2026/a.md
        mkdir -p /m/j/2026
        touch /m/j/b.md
        echo ok > /m/d/2026/a.md
        """)

      reachable = walked(bash.fs, "/m")

      assert reachable == ["/m", "/m/d", "/m/d/2026", "/m/d/2026/a.md", "/m/j"]

      for path <- ["/m/j/2026/a.md", "/m/j/b.md", "/m/j/2026"] do
        refute path in reachable
        assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, path)
      end
    end
  end

  describe "inconsistent initial file maps" do
    test "JustBash.new/1 raises when one file path runs through another" do
      assert_raise ArgumentError, ~r|"/m/j".*"/m/j/a\.md"|s, fn ->
        JustBash.new(files: %{"/m/j" => "x", "/m/j/a.md" => "y"})
      end
    end

    test "JustBash.new/1 raises for a deeper conflict" do
      assert_raise ArgumentError, fn ->
        JustBash.new(files: %{"/m/j" => "x", "/m/j/2026/a.md" => "y"})
      end
    end

    test "FS.new/1 raises for the same conflict" do
      assert_raise ArgumentError, fn ->
        FS.new(%{"/m/j" => "x", "/m/j/a.md" => "y"})
      end
    end

    test "the memory backend raises for the same conflict" do
      assert_raise ArgumentError, fn ->
        Memory.new(%{"/m/j" => "x", "/m/j/a.md" => "y"})
      end
    end

    test "a shared path prefix that is not a component boundary is fine" do
      bash = JustBash.new(files: %{"/m/jj" => "x", "/m/j" => "y"})
      {result, _bash} = JustBash.exec(bash, "cat /m/jj /m/j")
      assert result.stdout == "xy"
    end

    test "consistent nested maps still work" do
      bash = JustBash.new(files: %{"/m/j/a.md" => "x", "/m/j/b.md" => "y"})
      {result, _bash} = JustBash.exec(bash, "cat /m/j/a.md /m/j/b.md")
      assert result.stdout == "xy"
    end

    test "raises when a file path collides with a default directory" do
      assert_raise ArgumentError, ~r|/tmp|, fn ->
        JustBash.new(files: %{"/tmp" => "not a dir"})
      end
    end
  end
end
