defmodule JustBash.Fs.GitFSTest do
  use ExUnit.Case, async: false

  alias JustBash.Fs
  alias JustBash.Fs.GitFS
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Fs.OverlayFS

  @moduletag :git_fs
  @moduletag timeout: 120_000

  @skills_url "https://github.com/anthropics/skills"

  setup_all do
    ro = GitFS.new(@skills_url)
    rw = GitFS.new(@skills_url, writable: true)
    %{ro_state: ro, rw_state: rw}
  end

  describe "read-only GitFS backend" do
    test "exists? returns true for root", %{ro_state: s} do
      assert GitFS.exists?(s, "/")
    end

    test "lists root directory entries", %{ro_state: s} do
      {:ok, entries} = GitFS.readdir(s, "/")
      assert is_list(entries)
      assert entries != []
    end

    test "reads a file", %{ro_state: s} do
      {:ok, entries} = GitFS.readdir(s, "/")
      file = Enum.find(entries, &String.ends_with?(&1, ".md"))

      if file do
        {:ok, content} = GitFS.read_file(s, "/#{file}")
        assert is_binary(content)
        assert byte_size(content) > 0
      end
    end

    test "stat returns directory info for root", %{ro_state: s} do
      {:ok, info} = GitFS.stat(s, "/")
      assert info.is_directory
      refute info.is_file
    end

    test "write operations return :erofs", %{ro_state: s} do
      assert {:error, :erofs} = GitFS.write_file(s, "/test", "data", [])
      assert {:error, :erofs} = GitFS.mkdir(s, "/dir", [])
      assert {:error, :erofs} = GitFS.rm(s, "/file", [])
      assert {:error, :erofs} = GitFS.append_file(s, "/file", "x")
      assert {:error, :erofs} = GitFS.chmod(s, "/file", 0o755)
      assert {:error, :erofs} = GitFS.symlink(s, "target", "/link")
      assert {:error, :erofs} = GitFS.link(s, "/a", "/b")
    end
  end

  describe "writable GitFS backend" do
    test "write_file creates a new file", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/new.txt", "hello", [])
      assert {:ok, "hello"} = GitFS.read_file(s, "/new.txt")
    end

    test "write_file overwrites existing file", %{rw_state: s} do
      {:ok, entries} = GitFS.readdir(s, "/")
      file = Enum.find(entries, &String.ends_with?(&1, ".md"))

      if file do
        {:ok, s} = GitFS.write_file(s, "/#{file}", "replaced", [])
        assert {:ok, "replaced"} = GitFS.read_file(s, "/#{file}")
      end
    end

    test "append_file adds to existing content", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/log.txt", "line1\n", [])
      {:ok, s} = GitFS.append_file(s, "/log.txt", "line2\n")
      assert {:ok, "line1\nline2\n"} = GitFS.read_file(s, "/log.txt")
    end

    test "rm removes a file", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/doomed.txt", "bye", [])
      assert GitFS.exists?(s, "/doomed.txt")

      {:ok, s} = GitFS.rm(s, "/doomed.txt", [])
      refute GitFS.exists?(s, "/doomed.txt")
    end

    test "rm returns :enoent for missing file", %{rw_state: s} do
      assert {:error, :enoent} = GitFS.rm(s, "/nope.txt", [])
    end

    test "rm force on missing file returns :ok", %{rw_state: s} do
      {:ok, _s} = GitFS.rm(s, "/nope.txt", force: true)
    end

    test "rm on directory without recursive returns :eisdir", %{rw_state: s} do
      {:ok, entries} = GitFS.readdir(s, "/")
      dir = Enum.find(entries, fn name -> not String.contains?(name, ".") end)

      if dir do
        assert {:error, :eisdir} = GitFS.rm(s, "/#{dir}", [])
      end
    end

    test "mkdir creates a directory", %{rw_state: s} do
      {:ok, s} = GitFS.mkdir(s, "/newdir", [])
      assert GitFS.exists?(s, "/newdir")
      {:ok, info} = GitFS.stat(s, "/newdir")
      assert info.is_directory
    end

    test "chmod changes file mode", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/script.sh", "#!/bin/bash", [])
      {:ok, s} = GitFS.chmod(s, "/script.sh", 0o755)
      {:ok, info} = GitFS.stat(s, "/script.sh")
      assert info.mode == 0o100755
    end

    test "original repo files still readable after writes", %{rw_state: s} do
      {:ok, entries_before} = GitFS.readdir(s, "/")
      {:ok, s} = GitFS.write_file(s, "/added.txt", "new", [])
      {:ok, entries_after} = GitFS.readdir(s, "/")

      for entry <- entries_before do
        assert entry in entries_after
      end

      assert "added.txt" in entries_after
    end
  end

  describe "read-only mount in VFS" do
    setup %{ro_state: ro_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, ro_state)
      %{fs: fs}
    end

    test "can list /skills directory", %{fs: fs} do
      {:ok, entries} = Fs.readdir(fs, "/skills")
      assert entries != []
    end

    test "writes to /skills are rejected", %{fs: fs} do
      assert {:error, :erofs} = Fs.write_file(fs, "/skills/new.txt", "data")
    end

    test "root fs still writable alongside git mount", %{fs: fs} do
      {:ok, fs} = Fs.write_file(fs, "/local.txt", "hello")
      {:ok, "hello"} = Fs.read_file(fs, "/local.txt")

      {:ok, skills_entries} = Fs.readdir(fs, "/skills")
      assert skills_entries != []
    end
  end

  describe "read-write mount in VFS" do
    setup %{rw_state: rw_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, rw_state)
      bash = JustBash.new(fs: fs)
      %{bash: bash}
    end

    test "can read and write to the git mount", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "ls /skills")
      assert result.exit_code == 0
      assert result.stdout != ""

      {result, bash} = JustBash.exec(bash, "echo 'agent note' > /skills/notes.txt")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "cat /skills/notes.txt")
      assert result.exit_code == 0
      assert result.stdout =~ "agent note"
    end

    test "can append to existing repo files", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {_result, bash} =
          JustBash.exec(bash, "echo '\n# Added by agent' >> /skills/#{md_file}")

        {result, _bash} = JustBash.exec(bash, "cat /skills/#{md_file}")
        assert result.exit_code == 0
        assert result.stdout =~ "Added by agent"
      end
    end

    test "can delete from the git mount", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      target = Enum.find(files, &String.ends_with?(&1, ".md"))

      if target do
        {result, bash} = JustBash.exec(bash, "rm /skills/#{target}")
        assert result.exit_code == 0

        {result, _bash} = JustBash.exec(bash, "ls /skills")
        refute result.stdout =~ ~r/\b#{Regex.escape(target)}\b/
      end
    end
  end

  describe "agent loop demo — bash over read-only git mount" do
    setup %{ro_state: ro_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, ro_state)
      bash = JustBash.new(fs: fs)
      %{bash: bash}
    end

    test "ls /skills lists repo contents", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "ls /skills")
      assert result.exit_code == 0
      assert result.stdout != ""
    end

    test "cat reads a file from the mounted repo", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {cat_result, _bash} = JustBash.exec(bash, "cat /skills/#{md_file}")
        assert cat_result.exit_code == 0
        assert cat_result.stdout != ""
      end
    end

    test "find lists files recursively", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "find /skills -type f")
      assert result.exit_code == 0
      files = String.split(result.stdout, "\n", trim: true)
      assert files != []
    end

    test "can copy from git to local", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {cp_result, bash} = JustBash.exec(bash, "cp /skills/#{md_file} /tmp/copy.md")
        assert cp_result.exit_code == 0

        {cat_result, _bash} = JustBash.exec(bash, "cat /tmp/copy.md")
        assert cat_result.exit_code == 0
        assert cat_result.stdout != ""
      end
    end
  end

  describe "OverlayFS over GitFS" do
    setup %{ro_state: ro_state} do
      overlay = OverlayFS.new(lower: {GitFS, ro_state})
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", OverlayFS, overlay)
      bash = JustBash.new(fs: fs)
      %{bash: bash}
    end

    test "reads fall through, writes go to upper layer", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "ls /skills")
      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "echo 'overlay' > /skills/overlay.txt")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "cat /skills/overlay.txt")
      assert result.stdout =~ "overlay"
    end
  end

  describe "layered backends — git + in-memory at different paths" do
    setup %{ro_state: ro_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, ro_state)
      {:ok, fs} = Fs.mount(fs, "/workspace", InMemoryFs, InMemoryFs.new())
      bash = JustBash.new(fs: fs)
      %{bash: bash}
    end

    test "read from git, write to workspace", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {result, bash} = JustBash.exec(bash, "cp /skills/#{md_file} /workspace/copy.md")
        assert result.exit_code == 0

        {result, _bash} = JustBash.exec(bash, "cat /workspace/copy.md")
        assert result.exit_code == 0
        assert result.stdout != ""
      end
    end

    test "workspace is writable, skills is read-only", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "echo 'hello' > /workspace/test.txt")
      assert result.exit_code == 0

      {result, _bash} =
        JustBash.exec(bash, "echo 'nope' > /skills/test.txt 2>&1 || echo FAIL")

      assert result.stdout =~ "FAIL" or result.exit_code != 0
    end

    test "ls / shows both mount points", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "ls /")
      assert result.exit_code == 0
      assert result.stdout =~ "skills"
      assert result.stdout =~ "workspace"
    end
  end
end
