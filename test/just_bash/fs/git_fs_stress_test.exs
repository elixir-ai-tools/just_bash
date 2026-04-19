defmodule JustBash.Fs.GitFSStressTest do
  use ExUnit.Case, async: false

  alias Exgit.Object.Commit
  alias Exgit.ObjectStore
  alias JustBash.Fs
  alias JustBash.Fs.GitFS
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Fs.OverlayFS

  @moduletag :git_fs
  @moduletag timeout: 120_000

  @skills_url "https://github.com/anthropics/skills"

  setup_all do
    rw = GitFS.new(@skills_url, writable: true)
    ro = GitFS.new(@skills_url)
    %{rw_state: rw, ro_state: ro}
  end

  describe "multi-step state consistency on writable GitFS" do
    test "20+ sequential write/read cycles stay coherent", %{rw_state: s} do
      s =
        Enum.reduce(1..25, s, fn i, acc ->
          content = "file #{i} content: #{:rand.uniform(1_000_000)}"
          {:ok, acc} = GitFS.write_file(acc, "/batch/file_#{i}.txt", content, [])
          assert {:ok, ^content} = GitFS.read_file(acc, "/batch/file_#{i}.txt")
          acc
        end)

      {:ok, entries} = GitFS.readdir(s, "/batch")
      assert length(entries) == 25

      Enum.each(1..25, fn i ->
        assert GitFS.exists?(s, "/batch/file_#{i}.txt")
      end)
    end

    test "write-delete-rewrite cycles", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/cycle.txt", "v1", [])
      assert {:ok, "v1"} = GitFS.read_file(s, "/cycle.txt")

      {:ok, s} = GitFS.rm(s, "/cycle.txt", [])
      refute GitFS.exists?(s, "/cycle.txt")
      assert {:error, :enoent} = GitFS.read_file(s, "/cycle.txt")

      {:ok, s} = GitFS.write_file(s, "/cycle.txt", "v2", [])
      assert {:ok, "v2"} = GitFS.read_file(s, "/cycle.txt")

      {:ok, s} = GitFS.rm(s, "/cycle.txt", [])
      {:ok, s} = GitFS.write_file(s, "/cycle.txt", "v3", [])
      assert {:ok, "v3"} = GitFS.read_file(s, "/cycle.txt")
    end

    test "interleaved writes and deletes across directories", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/a/x.txt", "ax", [])
      {:ok, s} = GitFS.write_file(s, "/b/y.txt", "by", [])
      {:ok, s} = GitFS.write_file(s, "/a/z.txt", "az", [])

      {:ok, s} = GitFS.rm(s, "/a/x.txt", [])
      assert {:ok, "az"} = GitFS.read_file(s, "/a/z.txt")
      assert {:ok, "by"} = GitFS.read_file(s, "/b/y.txt")
      refute GitFS.exists?(s, "/a/x.txt")

      {:ok, entries} = GitFS.readdir(s, "/a")
      assert "z.txt" in entries
      refute "x.txt" in entries
    end

    test "original repo files survive many writes", %{rw_state: s} do
      {:ok, original_entries} = GitFS.readdir(s, "/")

      s =
        Enum.reduce(1..10, s, fn i, acc ->
          {:ok, acc} = GitFS.write_file(acc, "/added_#{i}.txt", "new #{i}", [])
          acc
        end)

      for entry <- original_entries do
        assert GitFS.exists?(s, "/#{entry}"),
               "original entry '#{entry}' disappeared after writes"
      end
    end
  end

  describe "rm -r on writable GitFS" do
    test "rm -r removes a directory with files", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/rmdir/a.txt", "a", [])
      {:ok, s} = GitFS.write_file(s, "/rmdir/b.txt", "b", [])
      {:ok, s} = GitFS.write_file(s, "/rmdir/sub/c.txt", "c", [])

      assert GitFS.exists?(s, "/rmdir")
      assert GitFS.exists?(s, "/rmdir/a.txt")
      assert GitFS.exists?(s, "/rmdir/sub/c.txt")

      {:ok, s} = GitFS.rm(s, "/rmdir", recursive: true)
      refute GitFS.exists?(s, "/rmdir")
      refute GitFS.exists?(s, "/rmdir/a.txt")
      refute GitFS.exists?(s, "/rmdir/sub/c.txt")
    end

    test "rm -r on repo directory removes it", %{rw_state: s} do
      {:ok, entries} = GitFS.readdir(s, "/")
      dir = Enum.find(entries, fn name -> not String.contains?(name, ".") end)

      if dir do
        {:ok, s} = GitFS.rm(s, "/#{dir}", recursive: true)
        refute GitFS.exists?(s, "/#{dir}")
      end
    end
  end

  describe "deeply nested path creation" do
    test "write to deep path creates intermediate directories", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/deep/a/b/c/d/file.txt", "deep content", [])
      assert {:ok, "deep content"} = GitFS.read_file(s, "/deep/a/b/c/d/file.txt")
      assert GitFS.exists?(s, "/deep/a/b/c/d")
      assert GitFS.exists?(s, "/deep/a/b/c")
      assert GitFS.exists?(s, "/deep/a/b")
      assert GitFS.exists?(s, "/deep/a")
      assert GitFS.exists?(s, "/deep")
    end

    test "write to multiple deep paths shares intermediate trees", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/shared/dir/file1.txt", "one", [])
      {:ok, s} = GitFS.write_file(s, "/shared/dir/file2.txt", "two", [])
      {:ok, s} = GitFS.write_file(s, "/shared/other/file3.txt", "three", [])

      {:ok, entries} = GitFS.readdir(s, "/shared/dir")
      assert "file1.txt" in entries
      assert "file2.txt" in entries

      {:ok, entries} = GitFS.readdir(s, "/shared")
      assert "dir" in entries
      assert "other" in entries
    end
  end

  describe "edge cases" do
    test "empty content", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/empty.txt", "", [])
      assert {:ok, ""} = GitFS.read_file(s, "/empty.txt")
      {:ok, info} = GitFS.stat(s, "/empty.txt")
      assert info.is_file
    end

    test "binary content", %{rw_state: s} do
      binary = <<0, 1, 2, 3, 255, 254, 253, 0, 0, 128>>
      {:ok, s} = GitFS.write_file(s, "/binary.bin", binary, [])
      assert {:ok, ^binary} = GitFS.read_file(s, "/binary.bin")
    end

    test "large content", %{rw_state: s} do
      large = String.duplicate("x", 100_000)
      {:ok, s} = GitFS.write_file(s, "/large.txt", large, [])
      {:ok, content} = GitFS.read_file(s, "/large.txt")
      assert byte_size(content) == 100_000
    end

    test "overwrite file with different size", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/size.txt", "short", [])
      {:ok, s} = GitFS.write_file(s, "/size.txt", String.duplicate("long ", 1000), [])
      {:ok, content} = GitFS.read_file(s, "/size.txt")
      assert byte_size(content) == 5000
    end

    test "delete last file in directory prunes empty tree", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/lonely/only.txt", "alone", [])
      assert GitFS.exists?(s, "/lonely")

      {:ok, s} = GitFS.rm(s, "/lonely/only.txt", [])

      refute GitFS.exists?(s, "/lonely"),
             "empty directory should be pruned after last file deleted"
    end

    test "stat on deleted path returns :enoent", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/ephemeral.txt", "poof", [])
      {:ok, s} = GitFS.rm(s, "/ephemeral.txt", [])
      assert {:error, :enoent} = GitFS.stat(s, "/ephemeral.txt")
      assert {:error, :enoent} = GitFS.read_file(s, "/ephemeral.txt")
    end

    test "readdir on deleted directory returns :enoent", %{rw_state: s} do
      {:ok, s} = GitFS.write_file(s, "/gone_dir/file.txt", "x", [])
      {:ok, s} = GitFS.rm(s, "/gone_dir", recursive: true)
      assert {:error, :enoent} = GitFS.readdir(s, "/gone_dir")
    end

    test "append to nonexistent file returns :enoent", %{rw_state: s} do
      assert {:error, :enoent} = GitFS.append_file(s, "/no_such_file.txt", "data")
    end
  end

  describe "realistic agent loop — multi-step bash workflow" do
    test "agent reads skills, creates summary, edits it, reorganizes", %{rw_state: rw_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/skills", GitFS, rw_state)
      bash = JustBash.new(fs: fs)

      # Step 1: discover what's in the repo
      {result, bash} = JustBash.exec(bash, "find /skills -type f | head -20")
      assert result.exit_code == 0
      files = String.split(result.stdout, "\n", trim: true)
      assert files != [], "agent should find files in the repo"

      # Step 2: read a file and extract info
      target = List.first(files)
      {result, bash} = JustBash.exec(bash, "wc -l #{target}")
      assert result.exit_code == 0

      # Step 3: create a new file based on what we found
      {result, bash} =
        JustBash.exec(bash, """
        echo "# Analysis Report" > /skills/report.md
        echo "" >> /skills/report.md
        echo "Files found: #{length(files)}" >> /skills/report.md
        echo "First file: #{target}" >> /skills/report.md
        """)

      assert result.exit_code == 0

      # Step 4: verify the report
      {result, bash} = JustBash.exec(bash, "cat /skills/report.md")
      assert result.exit_code == 0
      assert result.stdout =~ "Analysis Report"
      assert result.stdout =~ "Files found:"

      # Step 5: create a workspace directory and copy files into it
      {result, bash} = JustBash.exec(bash, "mkdir -p /skills/workspace")
      assert result.exit_code == 0

      {result, bash} =
        JustBash.exec(bash, "cp /skills/report.md /skills/workspace/report_copy.md")

      assert result.exit_code == 0

      # Step 6: verify both copies exist
      {result, bash} = JustBash.exec(bash, "cat /skills/workspace/report_copy.md")
      assert result.exit_code == 0
      assert result.stdout =~ "Analysis Report"

      # Step 7: clean up — delete the original report
      {result, bash} = JustBash.exec(bash, "rm /skills/report.md")
      assert result.exit_code == 0

      # Step 8: verify original is gone but copy survives
      {result, bash} =
        JustBash.exec(bash, "test -f /skills/report.md && echo EXISTS || echo GONE")

      assert result.stdout =~ "GONE"

      {result, _bash} = JustBash.exec(bash, "cat /skills/workspace/report_copy.md")
      assert result.exit_code == 0
      assert result.stdout =~ "Analysis Report"
    end

    test "agent processes multiple files in a loop", %{rw_state: rw_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/repo", GitFS, rw_state)
      bash = JustBash.new(fs: fs)

      # Create several data files
      {result, bash} =
        JustBash.exec(bash, """
        for i in 1 2 3 4 5; do
          echo "data line $i" > /repo/data_$i.txt
        done
        """)

      assert result.exit_code == 0

      # Verify all files exist
      {result, bash} = JustBash.exec(bash, "ls /repo | grep data_ | wc -l")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "5"

      # Concatenate them
      {result, bash} =
        JustBash.exec(bash, "cat /repo/data_1.txt /repo/data_2.txt /repo/data_3.txt")

      assert result.exit_code == 0
      assert result.stdout =~ "data line 1"
      assert result.stdout =~ "data line 2"
      assert result.stdout =~ "data line 3"

      # Delete some
      {result, bash} =
        JustBash.exec(bash, """
        rm /repo/data_1.txt /repo/data_3.txt /repo/data_5.txt
        """)

      assert result.exit_code == 0

      # Only 2 and 4 remain
      {result, _bash} = JustBash.exec(bash, "ls /repo | grep data_")
      assert result.exit_code == 0
      assert result.stdout =~ "data_2"
      assert result.stdout =~ "data_4"
      refute result.stdout =~ "data_1"
      refute result.stdout =~ "data_3"
      refute result.stdout =~ "data_5"
    end
  end

  describe "realistic agent loop — OverlayFS over GitFS" do
    test "agent modifies repo via overlay, lower layer untouched", %{ro_state: ro_state} do
      overlay = OverlayFS.new(lower: {GitFS, ro_state})
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/repo", OverlayFS, overlay)
      bash = JustBash.new(fs: fs)

      # Read original content
      {ls_result, bash} = JustBash.exec(bash, "ls /repo")
      original_files = String.split(ls_result.stdout, ~r/\s+/, trim: true)

      # Write new files
      {result, bash} = JustBash.exec(bash, "echo 'overlay content' > /repo/overlay.txt")
      assert result.exit_code == 0

      # Read back
      {result, bash} = JustBash.exec(bash, "cat /repo/overlay.txt")
      assert result.stdout =~ "overlay content"

      # Original files still visible
      {result, bash} = JustBash.exec(bash, "ls /repo")

      for file <- original_files do
        assert result.stdout =~ file,
               "original file '#{file}' should still be visible through overlay"
      end

      # Delete an original file via overlay
      md_file = Enum.find(original_files, &String.ends_with?(&1, ".md"))

      if md_file do
        {result, bash} = JustBash.exec(bash, "rm /repo/#{md_file}")
        assert result.exit_code == 0

        {result, _bash} = JustBash.exec(bash, "test -f /repo/#{md_file} && echo YES || echo NO")
        assert result.stdout =~ "NO"
      end

      # Verify the lower layer is unchanged
      assert GitFS.exists?(ro_state, "/#{md_file}"),
             "lower layer should be unmodified"
    end
  end

  describe "git-verification — sync to disk and verify with real git" do
    test "modified tree produces valid git objects on disk", %{rw_state: s} do
      # Make some modifications
      {:ok, s} = GitFS.write_file(s, "/verified/hello.txt", "hello from agent\n", [])
      {:ok, s} = GitFS.write_file(s, "/verified/data.csv", "a,b,c\n1,2,3\n", [])
      {:ok, s} = GitFS.write_file(s, "/verified/nested/deep.txt", "deep content\n", [])

      # Create a commit from the current tree
      tree_sha = s.tree
      timestamp = "1700000000 +0000"
      author = "Test Agent <agent@test.com> #{timestamp}"

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: author,
          committer: author,
          message: "Agent modifications"
        )

      {:ok, commit_sha, store} = ObjectStore.put(s.repo.object_store, commit)
      repo = %{s.repo | object_store: store}

      # Init a bare repo on disk and export all objects
      tmp_dir = System.tmp_dir!() |> Path.join("git_fs_verify_#{:rand.uniform(999_999)}")
      File.rm_rf!(tmp_dir)
      {:ok, disk_repo} = Exgit.init(path: tmp_dir)

      # Export objects from memory to disk
      all_objects =
        repo.object_store.objects
        |> Enum.map(fn {sha, {type, compressed}} ->
          content = :zlib.uncompress(compressed)
          {:ok, obj} = Exgit.Object.decode(type, content)
          {sha, obj}
        end)

      disk_store =
        Enum.reduce(all_objects, disk_repo.object_store, fn {_sha, obj}, store ->
          {:ok, _sha, store} = ObjectStore.put(store, obj)
          store
        end)

      disk_repo = %{disk_repo | object_store: disk_store}

      # Write the ref
      {:ok, ref_store} =
        Exgit.RefStore.write(disk_repo.ref_store, "refs/heads/main", commit_sha, [])

      _disk_repo = %{disk_repo | ref_store: ref_store}

      # Now verify with real git
      commit_hex = Base.encode16(commit_sha, case: :lower)

      {output, 0} =
        System.cmd("git", ["--git-dir", tmp_dir, "log", "--oneline", commit_hex],
          stderr_to_stdout: true
        )

      assert output =~ "Agent modifications"

      # Verify the tree contents
      tree_hex = Base.encode16(tree_sha, case: :lower)

      {output, 0} =
        System.cmd("git", ["--git-dir", tmp_dir, "ls-tree", "-r", tree_hex],
          stderr_to_stdout: true
        )

      assert output =~ "verified/hello.txt"
      assert output =~ "verified/data.csv"
      assert output =~ "verified/nested/deep.txt"

      # Verify actual file content
      # Find the blob sha for hello.txt
      hello_line = output |> String.split("\n") |> Enum.find(&(&1 =~ "hello.txt"))
      [_mode, _type, blob_hex | _] = String.split(hello_line)
      blob_hex = String.split(blob_hex, "\t") |> List.first()

      {content, 0} =
        System.cmd("git", ["--git-dir", tmp_dir, "cat-file", "-p", blob_hex],
          stderr_to_stdout: true
        )

      assert content == "hello from agent\n"

      # Clean up
      File.rm_rf!(tmp_dir)
    end
  end

  describe "realistic agent loop — multi-mount workspace" do
    test "agent reads from git, processes in workspace, writes results", %{ro_state: ro_state} do
      fs = Fs.new()
      {:ok, fs} = Fs.mount(fs, "/source", GitFS, ro_state)
      {:ok, fs} = Fs.mount(fs, "/workspace", InMemoryFs, InMemoryFs.new())
      bash = JustBash.new(fs: fs)

      # Step 1: list source files
      {result, bash} = JustBash.exec(bash, "find /source -type f -name '*.md'")
      assert result.exit_code == 0
      md_files = String.split(result.stdout, "\n", trim: true)

      if md_files != [] do
        source_file = List.first(md_files)

        # Step 2: copy to workspace for processing
        {result, bash} = JustBash.exec(bash, "cp #{source_file} /workspace/input.md")
        assert result.exit_code == 0

        # Step 3: process the file
        {result, bash} =
          JustBash.exec(bash, "wc -l /workspace/input.md | awk '{print $1}'")

        assert result.exit_code == 0
        line_count = String.trim(result.stdout)

        # Step 4: write analysis
        {result, bash} =
          JustBash.exec(
            bash,
            "echo 'Lines: #{line_count}' > /workspace/analysis.txt"
          )

        assert result.exit_code == 0

        # Step 5: verify workspace has both files
        {result, bash} = JustBash.exec(bash, "ls /workspace")
        assert result.stdout =~ "input.md"
        assert result.stdout =~ "analysis.txt"

        # Step 6: verify source is still read-only
        {result, _bash} =
          JustBash.exec(bash, "echo 'x' > /source/test.txt 2>&1 || echo READONLY")

        assert result.stdout =~ "READONLY"
      end
    end
  end
end
