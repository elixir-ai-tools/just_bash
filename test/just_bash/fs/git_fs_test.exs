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
    state = GitFS.new(@skills_url)
    %{git_state: state}
  end

  describe "GitFS backend" do
    test "exists? returns true for root", %{git_state: state} do
      assert GitFS.exists?(state, "/")
    end

    test "lists root directory entries", %{git_state: state} do
      {:ok, entries} = GitFS.readdir(state, "/")
      assert is_list(entries)
      assert entries != []
    end

    test "reads a file from root", %{git_state: state} do
      {:ok, entries} = GitFS.readdir(state, "/")
      file = Enum.find(entries, &String.ends_with?(&1, ".md"))

      if file do
        {:ok, content} = GitFS.read_file(state, "/#{file}")
        assert is_binary(content)
        assert byte_size(content) > 0
      end
    end

    test "stat returns directory info for root", %{git_state: state} do
      {:ok, info} = GitFS.stat(state, "/")
      assert info.is_directory
      refute info.is_file
    end

    test "write operations return :erofs", %{git_state: state} do
      assert {:error, :erofs} = GitFS.write_file(state, "/test", "data", [])
      assert {:error, :erofs} = GitFS.mkdir(state, "/dir", [])
      assert {:error, :erofs} = GitFS.rm(state, "/file", [])
    end
  end

  describe "mounted in VFS" do
    setup %{git_state: git_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, git_state)
      %{fs: fs}
    end

    test "can list /skills directory", %{fs: fs} do
      {:ok, entries} = Fs.readdir(fs, "/skills")
      assert is_list(entries)
      assert entries != []
    end

    test "can stat /skills as directory", %{fs: fs} do
      {:ok, info} = Fs.stat(fs, "/skills")
      assert info.is_directory
    end

    test "can read files from /skills", %{fs: fs} do
      {:ok, entries} = Fs.readdir(fs, "/skills")
      file = Enum.find(entries, &String.ends_with?(&1, ".md"))

      if file do
        {:ok, content} = Fs.read_file(fs, "/skills/#{file}")
        assert is_binary(content)
        assert byte_size(content) > 0
      end
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

  describe "agent loop demo — reading skills from GitHub" do
    setup %{git_state: git_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, git_state)
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
      assert ls_result.exit_code == 0

      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {cat_result, _bash} = JustBash.exec(bash, "cat /skills/#{md_file}")
        assert cat_result.exit_code == 0
        assert cat_result.stdout != ""
      end
    end

    test "find lists files recursively in mounted repo", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "find /skills -type f")
      assert result.exit_code == 0
      assert result.stdout != ""

      files = String.split(result.stdout, "\n", trim: true)
      assert files != []
    end

    test "wc -l counts lines in a skill file", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {wc_result, _bash} = JustBash.exec(bash, "wc -l /skills/#{md_file}")
        assert wc_result.exit_code == 0
        assert wc_result.stdout =~ ~r/\d+/
      end
    end

    test "grep searches across skill files", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "grep -r 'claude' /skills || true")
      assert result.exit_code in [0, 1]
    end

    test "can copy a skill file to local workspace", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      md_file = Enum.find(files, &String.ends_with?(&1, ".md"))

      if md_file do
        {cp_result, bash} = JustBash.exec(bash, "cp /skills/#{md_file} /tmp/local_copy.md")
        assert cp_result.exit_code == 0

        {cat_result, _bash} = JustBash.exec(bash, "cat /tmp/local_copy.md")
        assert cat_result.exit_code == 0
        assert cat_result.stdout != ""
      end
    end
  end

  describe "read-write git mount via OverlayFS" do
    setup %{git_state: git_state} do
      overlay = OverlayFS.new(lower: {GitFS, git_state})
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", OverlayFS, overlay)
      bash = JustBash.new(fs: fs)
      %{bash: bash}
    end

    test "can read existing repo files", %{bash: bash} do
      {result, _bash} = JustBash.exec(bash, "ls /skills")
      assert result.exit_code == 0
      assert result.stdout != ""
    end

    test "can write new files alongside repo content", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "echo 'my notes' > /skills/notes.txt")
      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "cat /skills/notes.txt")
      assert result.exit_code == 0
      assert result.stdout =~ "my notes"

      {result, _bash} = JustBash.exec(bash, "ls /skills")
      assert result.exit_code == 0
      assert result.stdout =~ "notes.txt"
    end

    test "can modify existing repo files", %{bash: bash} do
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

    test "can delete repo files", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      files = String.split(ls_result.stdout, ~r/\s+/, trim: true)
      target = List.first(files)

      if target do
        {result, bash} = JustBash.exec(bash, "rm /skills/#{target}")
        assert result.exit_code == 0

        {result, _bash} = JustBash.exec(bash, "ls /skills")
        refute result.stdout =~ ~r/\b#{Regex.escape(target)}\b/
      end
    end
  end

  describe "layered backends — git + in-memory at different paths" do
    setup %{git_state: git_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, git_state)
      {:ok, fs} = Fs.mount(fs, "/workspace", InMemoryFs, InMemoryFs.new())
      bash = JustBash.new(fs: fs)
      %{bash: bash}
    end

    test "read from git, write to workspace", %{bash: bash} do
      {ls_result, bash} = JustBash.exec(bash, "ls /skills")
      assert ls_result.exit_code == 0
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
      {result, bash} = JustBash.exec(bash, "echo 'hello' > /workspace/test.txt")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "echo 'nope' > /skills/test.txt 2>&1 || echo FAIL")
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
