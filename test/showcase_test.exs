defmodule JustBash.ShowcaseTest do
  @moduledoc """
  A guided tour of JustBash's vfs-backed filesystem, in runnable form.

      mix test test/showcase_test.exs --trace

  Four sections:

  1. **The filesystem is a value** — `bash.fs` is a `%VFS{}` you hold,
     thread, and fork like any other data.
  2. **Custom commands** — host-side commands read and write through
     `JustBash.FS`, threading state per the vfs contract.
  3. **Mounts** — any `VFS.Mountable` mounts into the environment and
     every bash command sees it.
  4. **Graceful degradation** — backends refuse what they can't do with
     structured errors, and scripts see ordinary exit codes.
  """

  use ExUnit.Case, async: true

  alias JustBash.FS

  describe "1. the filesystem is a value" do
    test "state threads through exec, and forks are free" do
      bash = JustBash.new(files: %{"/home/user/note.txt" => "draft\n"})

      # Executing a script returns a new environment; the old one is intact.
      {_result, after_edit} = JustBash.exec(bash, "echo final > note.txt")

      {result, _} = JustBash.exec(bash, "cat note.txt")
      assert result.stdout == "draft\n"

      {result, _} = JustBash.exec(after_edit, "cat note.txt")
      assert result.stdout == "final\n"

      # The same value is directly inspectable from the host, no shell needed.
      assert {:ok, "final\n", _fs} = FS.read_file(after_edit.fs, "/home/user/note.txt")
    end

    test "the default backend keeps full POSIX semantics" do
      bash = JustBash.new(files: %{"/home/user/target.txt" => "content\n"})

      {result, bash} =
        JustBash.exec(bash, """
        ln -s target.txt link
        readlink link
        [[ -L link ]] && echo is-a-symlink
        cat link
        """)

      assert result.stdout == "target.txt\nis-a-symlink\ncontent\n"

      # lstat sees the link; stat follows it — both through the mount table.
      assert {:ok, %VFS.Stat{type: :symlink}, _} = FS.lstat(bash.fs, "/home/user/link")
      assert {:ok, %VFS.Stat{type: :regular}, _} = FS.stat(bash.fs, "/home/user/link")
    end
  end

  describe "2. custom commands use JustBash.FS" do
    defmodule Upcase do
      @behaviour JustBash.Commands.Command

      @impl true
      def names, do: ["upcase"]

      @impl true
      def execute(bash, [path], _stdin) do
        resolved = FS.resolve_path(bash.cwd, path)

        # Reads return {:ok, payload, fs} — thread the fs forward so lazy
        # backends (a git mount fetching blobs on demand) keep their caches.
        case FS.read_file(bash.fs, resolved) do
          {:ok, content, fs} ->
            {:ok, fs} = FS.write_file(fs, resolved, String.upcase(content))
            {%{stdout: "", stderr: "", exit_code: 0}, %{bash | fs: fs}}

          {:error, %VFS.Error{} = err} ->
            msg = "upcase: #{path}: #{FS.strerror(err)}\n"
            {%{stdout: "", stderr: msg, exit_code: 1}, bash}
        end
      end
    end

    test "a host command reads, transforms, and writes back" do
      bash =
        JustBash.new(
          files: %{"/home/user/note.txt" => "hello"},
          commands: %{"upcase" => Upcase}
        )

      {result, bash} = JustBash.exec(bash, "upcase note.txt && cat note.txt")
      assert result.exit_code == 0
      assert result.stdout == "HELLO"

      # Structured errors become conventional messages via strerror/1.
      {result, _bash} = JustBash.exec(bash, "upcase missing.txt")
      assert result.exit_code == 1
      assert result.stderr == "upcase: missing.txt: No such file or directory\n"
    end
  end

  describe "3. mounts" do
    test "a mounted backend is just part of the tree" do
      data = VFS.Memory.new(%{"/users.csv" => "name\nalice\nbob\n"})

      bash =
        JustBash.new()
        |> JustBash.mount("/data", data)

      # Reads, globs, pipes — ordinary bash over the mount.
      {result, bash} = JustBash.exec(bash, "tail -n +2 /data/*.csv | sort")
      assert result.stdout == "alice\nbob\n"

      # Writes route to the owning mount; the root backend is untouched.
      {result, bash} = JustBash.exec(bash, "wc -l < /data/users.csv > /data/count.txt")
      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "cat /data/count.txt")
      assert String.trim(result.stdout) == "3"

      {exists, _fs} = FS.exists?(bash.fs, "/count.txt")
      refute exists

      # cp is a composition over the vfs primitives, so it crosses mounts.
      {result, bash} = JustBash.exec(bash, "cp /data/users.csv /tmp/backup.csv")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "cat /tmp/backup.csv")
      assert result.stdout == "name\nalice\nbob\n"
    end
  end

  describe "4. graceful degradation" do
    test "backends refuse what they can't do; scripts see exit codes" do
      bash =
        JustBash.new()
        |> JustBash.mount("/plain", VFS.Memory.new(%{"/f.txt" => "x"}))

      # VFS.Memory has no symlinks: ln -s fails with a structured error,
      # not a crash — and the script can handle it like any other failure.
      {result, bash} =
        JustBash.exec(bash, "ln -s f.txt /plain/link || echo 'fell back'")

      assert result.stderr =~ "Operation not supported"
      assert result.stdout == "fell back\n"

      # test -L is simply false where symlinks can't exist.
      {result, bash} = JustBash.exec(bash, "[[ -L /plain/f.txt ]]; echo $?")
      assert result.stdout == "1\n"

      # Unmounting removes the subtree.
      bash = JustBash.umount(bash, "/plain")
      {result, _bash} = JustBash.exec(bash, "cat /plain/f.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end
  end
end
