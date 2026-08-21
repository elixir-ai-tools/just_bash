defmodule JustBash.EmptyPathTest do
  @moduledoc """
  Regression tests for issue #79: an empty-string path operand used to
  resolve to the cwd, so every command reported "Is a directory" for `''`.

  POSIX is explicit that an empty pathname names nothing: it is `ENOENT`,
  never the current directory. `FS.resolve_path/2` is where that decision
  belongs — every file-operand command inherits it.
  """
  use ExUnit.Case, async: true

  alias JustBash.FS

  describe "FS.resolve_path/2" do
    test "an empty pathname is ENOENT, not the base" do
      assert FS.resolve_path("/home/user", "") == {:error, :enoent}
      assert FS.resolve_path("/", "") == {:error, :enoent}
    end

    test "a real relative path still resolves against the base" do
      assert FS.resolve_path("/home/user", "file.txt") == "/home/user/file.txt"
      assert FS.resolve_path("/home/user", "subdir/file") == "/home/user/subdir/file"
    end

    test "a bare / is the root" do
      assert FS.resolve_path("/home/user", "/") == "/"
    end

    test "repeated slashes collapse" do
      assert FS.resolve_path("/home/user", "//") == "/"
      assert FS.resolve_path("/home/user", "///") == "/"
      assert FS.resolve_path("/home/user", "foo//bar") == "/home/user/foo/bar"
    end

    test "a trailing . is the base" do
      assert FS.resolve_path("/home/user", ".") == "/home/user"
      assert FS.resolve_path("/home/user", "./") == "/home/user"
    end
  end

  describe "FS.check_directory_spelling/3" do
    test "an empty destination names nothing" do
      fs = FS.new(%{"/f" => "F\n", "/d/keep" => "K\n"})

      assert {:error, %VFS.Error{kind: :enoent, path: ""}} =
               FS.check_directory_spelling(fs, "/home/user", "")
    end
  end

  describe "empty source operands" do
    # $ cat ''
    # cat: : Is a directory          # was
    # gcat '': "cannot open '' for reading: No such file or directory"
    test "cat '' is ENOENT, not Is a directory" do
      {result, _} = JustBash.exec(JustBash.new(), "cat ''")

      assert result.exit_code == 1
      assert result.stderr == "cat: : No such file or directory\n"
      refute result.stderr =~ "Is a directory"
    end

    # $ sort ''
    # sort: read failed: : Is a directory          # was
    # gsort '': "cannot read: '': No such file or directory"
    test "sort '' is ENOENT, not Is a directory" do
      {result, _} = JustBash.exec(JustBash.new(), "sort ''")

      assert result.exit_code == 2
      assert result.stderr == "sort: cannot read: : No such file or directory\n"
      refute result.stderr =~ "Is a directory"
    end

    # Reachable without anyone typing '': `sort "$f"` with f unset.
    test "cat of an empty variable is ENOENT" do
      {result, _} = JustBash.exec(JustBash.new(), "f= && cat \"$f\"")

      assert result.exit_code == 1
      assert result.stderr == "cat: : No such file or directory\n"
      refute result.stderr =~ "Is a directory"
    end
  end

  describe "empty destination operands" do
    # $ touch ''
    # used to touch the cwd (a directory). GNU: cannot touch '': No such file
    test "touch '' is ENOENT, not a touch of the cwd" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "touch ''")

      assert result.exit_code == 1
      assert result.stderr == "touch: cannot touch '': No such file or directory\n"

      {ls, _} = JustBash.exec(bash, "ls -a /home/user")
      refute ls.stdout =~ ~r/(^|\n)''(\n|$)/
    end
  end

  describe "non-empty paths still work" do
    test "a real relative path still reads" do
      bash = JustBash.new(files: %{"/home/user/file.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "cat file.txt")

      assert result.exit_code == 0
      assert result.stdout == "hello\n"
    end

    test "/ still names the root" do
      bash = JustBash.new(files: %{"/home/user/file.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "ls /")

      assert result.exit_code == 0
      assert result.stdout =~ "home"
    end
  end
end
