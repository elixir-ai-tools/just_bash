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

  # A traversal that diverges must fail the test, not hang the suite — and
  # must not take the VM down with it. `:brutal_kill` reclaims whatever the
  # runaway traversal allocated along with the process that allocated it.
  defp within(fun, timeout \\ 5_000) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      _ -> flunk("did not terminate within #{timeout}ms")
    end
  end

  defp exec_within(bash, script) do
    {result, _bash} = within(fn -> JustBash.exec(bash, script) end)
    result
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

  # Every one of these asserts stdout as well as stderr: the output was
  # destined for the file, so a failed redirect must not spill it into the
  # stream the caller reads back.
  describe "shell redirections through a regular file" do
    test "> reports Not a directory when the parent is a regular file" do
      {result, bash} = JustBash.exec(bash_with_file_parent(), "echo hi > /m/j/a.md")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: /m/j/a.md: Not a directory\n"
      assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, "/m/j/a.md")
    end

    test "> reports Not a directory for a deeper path and stores nothing" do
      {result, bash} = JustBash.exec(bash_with_file_parent(), "echo hi > /m/j/2026/a.md")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: /m/j/2026/a.md: Not a directory\n"
      assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, "/m/j/2026/a.md")
      assert walked(bash.fs, "/m") == ["/m", "/m/j"]
    end

    test ">> reports Not a directory" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "echo hi >> /m/j/2026/a.md")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: /m/j/2026/a.md: Not a directory\n"
    end

    test "2> reports Not a directory and does not spill the command's stderr" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "ls /nope 2> /m/j/err.log")

      assert result.exit_code == 1
      assert result.stdout == ""
      # `ls: cannot access '/nope'` was redirected into the file, so only the
      # shell's own message about the failed redirect survives.
      assert result.stderr == "bash: /m/j/err.log: Not a directory\n"
    end

    test "&> reports Not a directory" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "echo hi &> /m/j/a.md")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: /m/j/a.md: Not a directory\n"
    end

    test ">> onto an existing directory does not spill stdout either" do
      {result, _bash} = JustBash.exec(JustBash.new(), "mkdir -p /d && echo hi >> /d")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: /d: Is a directory\n"
    end
  end

  describe "commands that create paths through a regular file" do
    # GNU coreutils 9.11 names the offending *ancestor* for -p, because that
    # is the directory it actually failed to create, and the full operand
    # without it:
    #   gmkdir j/2026           -> cannot create directory 'j/2026'
    #   gmkdir -p j/2026        -> cannot create directory 'j'
    #   gmkdir -p j/2026/deeper -> cannot create directory 'j'
    test "mkdir -p names the offending ancestor, not the full operand" do
      {result, bash} = JustBash.exec(bash_with_file_parent(), "mkdir -p /m/j/2026")

      assert result.exit_code == 1
      assert result.stderr == "mkdir: cannot create directory '/m/j': Not a directory\n"
      assert walked(bash.fs, "/m") == ["/m", "/m/j"]
    end

    test "mkdir -p names the offending ancestor for a deeper operand" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "mkdir -p /m/j/2026/deeper")

      assert result.exit_code == 1
      assert result.stderr == "mkdir: cannot create directory '/m/j': Not a directory\n"
    end

    # The ancestor is named as the operand expressed it, matching GNU.
    test "mkdir -p names the offending ancestor in the operand's own form" do
      bash = bash_with_file_parent()
      {result, _bash} = JustBash.exec(bash, "cd /m && mkdir -p j/2026")

      assert result.exit_code == 1
      assert result.stderr == "mkdir: cannot create directory 'j': Not a directory\n"
    end

    test "mkdir -p on a dangling symlink reports File exists" do
      {result, _bash} =
        JustBash.exec(JustBash.new(), "ln -s /nowhere /dang; mkdir -p /dang")

      assert result.exit_code == 1
      assert result.stderr == "mkdir: cannot create directory '/dang': File exists\n"
    end

    test "mkdir -p on a symlink to a directory still succeeds" do
      {result, _bash} =
        JustBash.exec(JustBash.new(), "mkdir -p /real && ln -s /real /link && mkdir -p /link")

      assert result.exit_code == 0
      assert result.stderr == ""
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

      # GNU stats the destination first, so ENOTDIR surfaces as `cannot stat`.
      # `cannot create regular file` stays the wording for :enoent.
      assert result.stderr == "cp: cannot stat '/m/j/a.md': Not a directory\n"

      assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, "/m/j/a.md")
    end

    test "cp -r reports Not a directory when an ancestor of the destination is a file" do
      bash = bash_with_file_parent(%{"/s/n.md" => "n\n"})
      {result, bash} = JustBash.exec(bash, "cp -r /s /m/j/sub")

      assert result.exit_code == 1

      # Same rule as the regular-file copy above: an ancestor that is a file is
      # a failed stat of the destination, not a failed overwrite. Verified
      # against GNU coreutils 9.11.
      assert result.stderr == "cp: cannot stat '/m/j/sub': Not a directory\n"

      assert {:error, %VFS.Error{}} = FS.read_file(bash.fs, "/m/j/sub/n.md")
    end

    test "cp -r keeps 'cannot overwrite non-directory' when the destination is the file" do
      bash = bash_with_file_parent(%{"/s/n.md" => "n\n"})
      {result, _bash} = JustBash.exec(bash, "cp -r /s /m/j")

      # The destination itself exists as a regular file — a different failure
      # from an ancestor being one, and GNU words it differently.
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot overwrite non-directory '/m/j' with directory '/s'\n"
    end

    test "cp keeps 'cannot create regular file' for a non-ENOTDIR failure" do
      bash = JustBash.new(files: %{"/src.txt" => "x\n"})
      {result, _bash} = JustBash.exec(bash, "mkdir -p /d && cp /src.txt /d")

      # /d is a directory, so this is :eisdir, not :enotdir.
      refute result.stderr =~ "cannot stat"
    end

    test "tee reports Not a directory for a deeper path too" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "echo hi | tee /m/j/2026/a.md")

      assert result.exit_code == 1
      assert result.stdout == "hi\n"
      assert result.stderr == "tee: /m/j/2026/a.md: Not a directory\n"
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

    # The companion invariant to "walk reaches everything": it also has to
    # stop. A `stat`-driven walk re-enters the tree through a symlinked
    # directory, so one self-link inflates the result and two make it
    # diverge — the store's keys are finite, the traversal over them was not.
    test "walk/3 terminates over a tree that contains a symlink cycle" do
      {_result, bash} =
        JustBash.exec(JustBash.new(), """
        mkdir -p /real/sub
        echo hi > /real/a.txt
        ln -s /real /real/s1
        ln -s /real /real/s2
        ln -s /real/sub /real/sub/back
        """)

      assert within(fn -> walked(bash.fs, "/real") end) ==
               [
                 "/real",
                 "/real/a.txt",
                 "/real/s1",
                 "/real/s2",
                 "/real/sub",
                 "/real/sub/back"
               ]
    end

    test "walk/3 yields each stored entry exactly once" do
      {_result, bash} =
        JustBash.exec(
          JustBash.new(),
          "mkdir -p /real; echo hi > /real/a.txt; ln -s /real /real/self"
        )

      walked =
        within(fn -> Enum.map(FS.walk(bash.fs, "/real", include_dirs: true), &elem(&1, 0)) end)

      assert Enum.sort(walked) == Enum.uniq(Enum.sort(walked))
    end

    test "walk/3 reports a symlink as a symlink rather than as its target" do
      {_result, bash} = JustBash.exec(JustBash.new(), "mkdir -p /real; ln -s /real /real/self")

      assert [{"/real/self", %VFS.Stat{type: :symlink}}] =
               within(fn -> Enum.to_list(FS.walk(bash.fs, "/real")) end)
    end

    test "walk/3 through a symlinked root reports paths under the root as asked" do
      {_result, bash} =
        JustBash.exec(
          JustBash.new(),
          "mkdir -p /real/sub; echo hi > /real/sub/a.txt; ln -s /real /link"
        )

      assert within(fn -> walked(bash.fs, "/link") end) ==
               ["/link", "/link/sub", "/link/sub/a.txt"]
    end

    test "walk/3 honors :max_depth relative to the root" do
      {_result, bash} =
        JustBash.exec(JustBash.new(), "mkdir -p /real/sub/deeper; echo hi > /real/sub/a.txt")

      assert within(fn ->
               bash.fs
               |> FS.walk("/real", include_dirs: true, max_depth: 1)
               |> Enum.map(&elem(&1, 0))
               |> Enum.sort()
             end) == ["/real", "/real/sub"]
    end
  end

  # `FS.stat/2` resolves symlinks, so a traversal that asks it "is this a
  # directory?" descends *through* a symlinked directory and back into the
  # tree it came from. One self-link inflates the output; two make the
  # traversal diverge (2^40 paths, bounded only by SYMLOOP_MAX), which
  # wedges the whole exec. GNU's default `-P` never descends into a
  # symlink, so the descent decision belongs to `FS.lstat/2`.
  describe "recursive commands do not descend into symlinked directories" do
    defp bash_with_self_link do
      {_result, bash} =
        JustBash.exec(JustBash.new(cwd: "/w"), """
        mkdir -p /w/real
        echo hi > /w/real/a.txt
        ln -s /w/real /w/real/self
        """)

      bash
    end

    defp bash_with_two_self_links do
      {_result, bash} =
        JustBash.exec(bash_with_self_link(), "ln -s /w/real /w/real/s2")

      bash
    end

    # Two real files, so grep prefixes its matches with filenames and a
    # match reached through a link is distinguishable from one that is not.
    defp bash_with_linked_subtree do
      {_result, bash} =
        JustBash.exec(JustBash.new(cwd: "/w"), """
        mkdir -p /w/real/sub
        echo hi > /w/real/a.txt
        echo hi > /w/real/sub/b.txt
        ln -s /w/real /w/real/self
        ln -s /w/real /w/real/s2
        """)

      bash
    end

    test "find lists the symlink and stops there" do
      assert exec_within(bash_with_self_link(), "find /w/real").stdout ==
               "/w/real\n/w/real/a.txt\n/w/real/self\n"
    end

    test "find terminates with two links back into the tree" do
      result = exec_within(bash_with_two_self_links(), "find /w/real")

      assert result.stdout == "/w/real\n/w/real/a.txt\n/w/real/s2\n/w/real/self\n"
    end

    test "find -type d does not match a symlink to a directory" do
      assert exec_within(bash_with_self_link(), "find /w/real -type d").stdout == "/w/real\n"
    end

    test "find -type f does not match a symlink to a file" do
      {_result, bash} = JustBash.exec(bash_with_self_link(), "ln -s /w/real/a.txt /w/real/lf")

      assert exec_within(bash, "find /w/real -type f").stdout == "/w/real/a.txt\n"
    end

    test "find -type l matches the symlinks and nothing else" do
      {_result, bash} = JustBash.exec(bash_with_self_link(), "ln -s /w/real/a.txt /w/real/lf")

      assert exec_within(bash, "find /w/real -type l").stdout == "/w/real/lf\n/w/real/self\n"
    end

    test "find on a symlink operand reports the link without descending" do
      {_result, bash} = JustBash.exec(bash_with_self_link(), "ln -s /w/real /w/link")

      assert exec_within(bash, "find /w/link").stdout == "/w/link\n"
    end

    test "du -s terminates and counts the tree once" do
      result = exec_within(bash_with_two_self_links(), "du -s /w/real")

      assert result.exit_code == 0
      assert [_line] = String.split(result.stdout, "\n", trim: true)
    end

    test "grep -r does not read files through a symlinked directory" do
      assert exec_within(bash_with_linked_subtree(), "grep -r hi /w/real").stdout ==
               "/w/real/a.txt:hi\n/w/real/sub/b.txt:hi\n"
    end

    # GNU grep follows a symlink named on the command line and skips the ones
    # it meets while recursing, so the operand link keeps working.
    test "grep -r still follows a symlink named on the command line" do
      {_result, bash} = JustBash.exec(bash_with_linked_subtree(), "ln -s /w/real /w/link")

      assert exec_within(bash, "grep -r hi /w/link").stdout ==
               "/w/link/a.txt:hi\n/w/link/sub/b.txt:hi\n"
    end

    test "tree terminates and lists the symlink once" do
      result = exec_within(bash_with_two_self_links(), "tree /w/real")

      assert result.exit_code == 0
      refute result.stdout =~ "self/"
      assert length(String.split(result.stdout, "self", trim: false)) == 2
    end
  end

  describe "cd reports resolution errors instead of raising" do
    test "cd through a regular file is ENOTDIR, matching bash" do
      before = bash_with_file_parent()
      {result, bash} = JustBash.exec(before, "cd /m/j/sub")

      assert result.exit_code == 1
      assert result.stderr == "bash: cd: /m/j/sub: Not a directory\n"
      assert bash.cwd == before.cwd
    end

    test "cd into a symlink loop is ELOOP, matching bash" do
      before = JustBash.new()
      {result, bash} = JustBash.exec(before, "ln -s /b /a; ln -s /a /b; cd /a")

      assert result.exit_code == 1
      assert result.stderr == "bash: cd: /a: Too many levels of symbolic links\n"
      assert bash.cwd == before.cwd
    end
  end

  describe "ls reports resolution errors instead of raising" do
    test "ls on a symlink loop is ELOOP" do
      {result, _bash} = JustBash.exec(JustBash.new(), "ln -s /b /a; ln -s /a /b; ls /a")

      assert result.exit_code == 1
      assert result.stderr == "ls: cannot access '/a': Too many levels of symbolic links\n"
      assert result.stdout == ""
    end

    test "ls through a regular file is ENOTDIR" do
      {result, _bash} = JustBash.exec(bash_with_file_parent(), "ls /m/j/sub")

      assert result.exit_code == 1
      assert result.stderr == "ls: cannot access '/m/j/sub': Not a directory\n"
    end
  end

  # A path resolves the same way whichever side of the filesystem asks.
  # Writes have followed intermediate symlinks since #53; if reads did not,
  # a write through a symlinked directory would land at the target and be
  # invisible at the path the caller used — the #53 bug class mirrored,
  # and worse, because the write reports success.
  describe "symlinked intermediate components resolve on the read side too" do
    defp fs_with_linked_dir do
      {:ok, fs} = FS.mkdir(FS.new(), "/real", parents: true)
      {:ok, fs} = FS.symlink(fs, "/real", "/link")
      fs
    end

    defp bash_with_linked_dir do
      {_result, bash} = JustBash.exec(JustBash.new(), "mkdir -p /real && ln -s /real /link")
      bash
    end

    test "read_file/2 sees a file written through the link" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/link/a.md", "hi\n")

      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/link/a.md")
      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/real/a.md")
    end

    test "read_file/2 sees a file written through a link and a created parent" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/link/sub/a.md", "hi\n")

      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/link/sub/a.md")
      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/real/sub/a.md")
    end

    test "stat/2 resolves an intermediate symlink" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/link/a.md", "hi\n")

      assert {:ok, %VFS.Stat{type: :regular, size: 3}, _fs} = FS.stat(fs, "/link/a.md")
    end

    test "exists?/2 resolves an intermediate symlink" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/link/a.md", "hi\n")

      assert FS.exists?(fs, "/link/a.md")
    end

    test "readdir/2 lists through a symlinked directory" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/link/a.md", "hi\n")

      assert {:ok, ["a.md"], _fs} = FS.readdir(fs, "/link")
      assert {:ok, ["a.md"], _fs} = FS.readdir(fs, "/real")
    end

    test "rm/3 removes a file addressed through the link" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/link/a.md", "hi\n")

      assert {:ok, fs} = FS.rm(fs, "/link/a.md")
      assert {:error, %VFS.Error{kind: :enoent}} = FS.read_file(fs, "/real/a.md")
    end

    test "rm/3 does not follow a symlink at the final component" do
      fs = fs_with_linked_dir()

      assert {:ok, fs} = FS.rm(fs, "/link")
      assert {:ok, %VFS.Stat{type: :directory}, _fs} = FS.stat(fs, "/real")
      assert {:error, %VFS.Error{kind: :enoent}} = FS.stat(fs, "/link")
    end

    test "lstat/2 resolves ancestors but reports the link at the final component" do
      {:ok, fs} = FS.symlink(fs_with_linked_dir(), "/real", "/real/inner")

      assert {:ok, %VFS.Stat{type: :symlink}, _fs} = FS.lstat(fs, "/link/inner")
      assert {:ok, %VFS.Stat{type: :symlink}, _fs} = FS.lstat(fs, "/link")
    end

    test "readlink/2 resolves ancestors but reads the link at the final component" do
      {:ok, fs} = FS.symlink(fs_with_linked_dir(), "/elsewhere", "/real/inner")

      assert {:ok, "/elsewhere", _fs} = FS.readlink(fs, "/link/inner")
    end

    test "link/3 resolves the source path's ancestors too" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/real/f", "x")

      assert {:ok, fs} = FS.link(fs, "/link/f", "/dst")
      assert {:ok, "x", _fs} = FS.read_file(fs, "/dst")
    end

    test "a chain that repeats a symlink without cycling still resolves" do
      {:ok, fs} = FS.mkdir(FS.new(), "/real", parents: true)
      {:ok, fs} = FS.symlink(fs, "/real", "/real/self")

      assert {:ok, fs} = FS.write_file(fs, "/real/self/self/x", "hi\n")
      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/real/x")
      assert {:ok, "hi\n", _fs} = FS.read_file(fs, "/real/self/self/x")
    end

    test "a genuine symlink cycle is :eloop on both sides" do
      {:ok, fs} = FS.symlink(FS.new(), "/b", "/a")
      {:ok, fs} = FS.symlink(fs, "/a", "/b")

      assert {:error, %VFS.Error{kind: :eloop}} = FS.write_file(fs, "/a/x", "hi\n")
      assert {:error, %VFS.Error{kind: :eloop}} = FS.read_file(fs, "/a/x")
      assert {:error, %VFS.Error{kind: :eloop}} = FS.read_file(fs, "/a")
    end

    test "walk/3 reaches everything written through the link, at its real path" do
      {:ok, fs} = FS.write_file(fs_with_linked_dir(), "/link/sub/a.md", "hi\n")

      assert walked(fs, "/real") == ["/real", "/real/sub", "/real/sub/a.md"]
    end

    test "> through a symlinked directory is readable at the path used" do
      {result, bash} =
        JustBash.exec(bash_with_linked_dir(), "echo hi > /link/a.md; cat /link/a.md")

      assert result.exit_code == 0
      assert result.stdout == "hi\n"
      assert {:ok, "hi\n", _fs} = FS.read_file(bash.fs, "/real/a.md")
    end

    test ">> through a symlinked directory is readable at the path used" do
      {result, _bash} =
        JustBash.exec(bash_with_linked_dir(), "echo a >> /link/ap.txt; cat /link/ap.txt")

      assert result.exit_code == 0
      assert result.stdout == "a\n"
    end

    test "cp through a symlinked directory is readable at the path used" do
      {result, _bash} =
        JustBash.exec(
          bash_with_linked_dir(),
          "echo x > /src.txt; cp /src.txt /link/c.txt; cat /link/c.txt"
        )

      assert result.exit_code == 0
      assert result.stdout == "x\n"
      assert result.stderr == ""
    end

    test "touch then ls through a symlinked directory" do
      {result, _bash} = JustBash.exec(bash_with_linked_dir(), "touch /link/t.txt && ls /link")

      assert result.exit_code == 0
      assert result.stdout == "t.txt\n"
    end

    test "mkdir -p then ls through a symlinked directory" do
      {result, bash} = JustBash.exec(bash_with_linked_dir(), "mkdir -p /link/sub && ls /link")

      assert result.exit_code == 0
      assert result.stdout == "sub\n"
      assert {:ok, %VFS.Stat{type: :directory}, _fs} = FS.stat(bash.fs, "/link/sub")
    end

    test "rm through a symlinked directory" do
      {result, _bash} = JustBash.exec(bash_with_linked_dir(), "echo hi > /link/f && rm /link/f")

      assert result.exit_code == 0
      assert result.stderr == ""
    end

    test "a relative write inside a symlinked cwd is readable back" do
      {result, _bash} =
        JustBash.exec(bash_with_linked_dir(), "cd /link && echo hi > f.txt && cat f.txt")

      assert result.exit_code == 0
      assert result.stdout == "hi\n"
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

    # The nested-path check cannot see every unrealizable map — a seed that
    # collides with a directory the backend already holds only fails at the
    # write. All three entry points should still report it the same way.
    test "the memory backend raises ArgumentError when a seed cannot be written" do
      assert_raise ArgumentError, ~r|"/"|, fn -> Memory.new(%{"/" => "x"}) end
    end

    test "FS.new/1 raises ArgumentError when a seed cannot be written" do
      assert_raise ArgumentError, ~r|"/"|, fn -> FS.new(%{"/" => "x"}) end
    end

    test "JustBash.new/1 raises ArgumentError when a seed cannot be written" do
      assert_raise ArgumentError, fn -> JustBash.new(files: %{"/" => "x"}) end
    end
  end
end
