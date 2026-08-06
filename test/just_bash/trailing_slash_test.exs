defmodule JustBash.TrailingSlashTest do
  @moduledoc """
  Regression tests for issue #58: a trailing slash used to be stripped from a
  destination operand, so `cp /a.md /f/` overwrote the regular file `/f`.

  POSIX resolves `f/` as `f/.`, which requires `f` to be a directory.
  `FS.resolve_path/2` normalizes the slash away, so every command that writes
  through a destination asks `FS.directory_spelling?/1` about the operand
  before trusting the resolved path.

  Every wording here was checked against GNU coreutils 9.11 and bash 5 —
  the shell transcript is quoted next to the case it came from.
  """
  use ExUnit.Case, async: true

  alias JustBash.FS

  # /f is a regular file, /d a directory, and the two symlinks reach one of
  # each: a trailing slash is about what the path *lands on*, not how it is
  # spelled on the way there.
  defp bash do
    JustBash.new(files: %{"/a.md" => "A\n", "/b.md" => "B\n", "/f" => "F\n", "/d/keep" => "K\n"})
  end

  defp bash_with_links do
    {result, bash} = JustBash.exec(bash(), "ln -s /f /lf && ln -s /d /ld")
    assert result.exit_code == 0
    bash
  end

  defp fs, do: FS.new(%{"/f" => "F\n", "/d/keep" => "K\n"})

  defp read(bash, path), do: FS.read_file(bash.fs, path)

  defp exists?(bash, path), do: bash.fs |> FS.exists?(path) |> elem(0)

  describe "cp with a destination spelled as a directory" do
    # $ cp a.md f/
    # cp: cannot stat 'f/': Not a directory
    test "refuses to overwrite a regular file and leaves it alone" do
      {result, bash} = JustBash.exec(bash(), "cp /a.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ cp a.md f/.
    # cp: cannot stat 'f/.': Not a directory
    test "refuses a trailing dot component too" do
      {result, bash} = JustBash.exec(bash(), "cp /a.md /f/.")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/f/.': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ cp -r src f/
    # cp: cannot stat 'f/': Not a directory
    test "refuses a recursive copy onto a regular file" do
      {result, bash} = JustBash.exec(bash(), "cp -r /d /f/")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ cp a.md a.md/
    # cp: cannot stat 'a.md/': Not a directory
    test "is not a self-copy: the source is not spelled as a directory" do
      {result, bash} = JustBash.exec(bash(), "cp /a.md /a.md/")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/a.md/': Not a directory\n"
      assert {:ok, "A\n", _fs} = read(bash, "/a.md")
    end

    # $ cp a.md nope/
    # cp: cannot create regular file 'nope/': No such file or directory
    test "will not create the file a slash promised would be a directory" do
      {result, bash} = JustBash.exec(bash(), "cp /a.md /nope/")

      assert result.exit_code == 1

      assert result.stderr ==
               "cp: cannot create regular file '/nope/': No such file or directory\n"

      refute exists?(bash, "/nope")
    end

    # $ cp -r src nope/  (creates the directory: the copy makes the promise true)
    test "a recursive copy creates the missing directory" do
      {result, bash} = JustBash.exec(bash(), "cp -r /d /nope/")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert {:ok, "K\n", _fs} = read(bash, "/nope/keep")
    end

    test "copying into a directory still works" do
      {result, bash} = JustBash.exec(bash(), "cp /a.md /d/")

      assert result.exit_code == 0
      assert {:ok, "A\n", _fs} = read(bash, "/d/a.md")
    end

    # $ cp a.md lfile/
    # cp: cannot stat 'lfile/': Not a directory
    test "follows a symlink before judging it: a link to a file is not a directory" do
      {result, bash} = JustBash.exec(bash_with_links(), "cp /a.md /lf/")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/lf/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    test "a symlink to a directory accepts the slash" do
      {result, bash} = JustBash.exec(bash_with_links(), "cp /a.md /ld/")

      assert result.exit_code == 0
      assert {:ok, "A\n", _fs} = read(bash, "/d/a.md")
    end

    # $ cp -n a.md f/
    # cp: cannot stat 'f/': Not a directory
    #
    # `-n` keeps an existing destination, but `f/` is not a name that file
    # has, so there is nothing for it to keep.
    test "-n does not quietly keep a destination that is not a directory" do
      {result, bash} = JustBash.exec(bash(), "cp -n /a.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ cp -P l f/
    # cp: cannot stat 'f/': Not a directory
    test "-P refuses the destination before copying the link itself" do
      {result, bash} = JustBash.exec(bash_with_links(), "cp -P /lf /f/")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ cp a.md b.md f/
    # cp: target 'f/': Not a directory
    test "several sources still name the target that is not a directory" do
      {result, bash} = JustBash.exec(bash(), "cp /a.md /b.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "cp: target '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end
  end

  describe "mv with a destination spelled as a directory" do
    # $ mv a.md f/
    # mv: cannot stat 'f/': Not a directory
    test "refuses to overwrite a regular file and keeps the source" do
      {result, bash} = JustBash.exec(bash(), "mv /a.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot stat '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
      assert {:ok, "A\n", _fs} = read(bash, "/a.md")
    end

    test "refuses a trailing dot component too" do
      {result, bash} = JustBash.exec(bash(), "mv /a.md /f/.")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot stat '/f/.': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ mv src f/
    # mv: cannot stat 'f/': Not a directory
    test "refuses to move a directory onto a regular file" do
      {result, bash} = JustBash.exec(bash(), "mv /d /f/")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot stat '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
      assert {:ok, "K\n", _fs} = read(bash, "/d/keep")
    end

    # $ mv a.md nope/
    # mv: cannot move 'a.md' to 'nope/': No such file or directory
    test "will not create the file a slash promised would be a directory" do
      {result, bash} = JustBash.exec(bash(), "mv /a.md /nope/")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot move '/a.md' to '/nope/': No such file or directory\n"
      assert {:ok, "A\n", _fs} = read(bash, "/a.md")
      refute exists?(bash, "/nope")
    end

    # $ mv src nope/  (a directory move makes the promise true)
    test "moving a directory to a missing destination renames it" do
      {result, bash} = JustBash.exec(bash(), "mv /d /nope/")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert {:ok, "K\n", _fs} = read(bash, "/nope/keep")
      refute exists?(bash, "/d")
    end

    test "moving into a directory still works" do
      {result, bash} = JustBash.exec(bash(), "mv /a.md /d/")

      assert result.exit_code == 0
      assert {:ok, "A\n", _fs} = read(bash, "/d/a.md")
      refute exists?(bash, "/a.md")
    end

    # $ mv missing.md f/
    # mv: cannot stat 'missing.md': No such file or directory
    test "reports a missing source before judging the destination" do
      {result, _bash} = JustBash.exec(bash(), "mv /missing.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot stat '/missing.md': No such file or directory\n"
    end
  end

  # A destination that resolves back to the source is the source, however the
  # directory holding it was spelled — the slash does not turn the refusal
  # into a silent exit-0 no-op. GNU coreutils 9.11, in a scratch directory:
  #
  #     $ mv d/keep d        mv: 'd/keep' and 'd/keep' are the same file
  #     $ mv d/keep d/       mv: 'd/keep' and 'd/keep' are the same file
  #     $ mv d/keep d/.      mv: 'd/keep' and 'd/./keep' are the same file
  #     $ mv d/keep d/../d/  mv: 'd/keep' and 'd/../d/keep' are the same file
  #     $ cd d && mv keep .  mv: 'keep' and './keep' are the same file
  #     $ cd d && mv keep ./ mv: 'keep' and './keep' are the same file
  #
  # GNU names each side the way the operand was written; we name both by where
  # they resolved, which is what `mv` did before this rule existed. The
  # refusal — and the untouched file — is what #58 is about.
  describe "mv onto a destination that resolves back to the source" do
    for {command, same} <- [
          {"mv /d/keep /d", "/d/keep"},
          {"mv /d/keep /d/", "/d/keep"},
          {"mv /d/keep /d/.", "/d/keep"},
          {"mv /d/keep /d/../d/", "/d/keep"},
          {"cd /d && mv keep .", "/d/keep"},
          {"cd /d && mv keep ./", "/d/keep"},
          {"mv /a.md /", "/a.md"},
          {"mv /a.md //", "/a.md"}
        ] do
      test "`#{command}` is refused rather than doing nothing quietly" do
        {result, bash} = JustBash.exec(bash(), unquote(command))

        assert result.exit_code == 1
        assert result.stdout == ""

        assert result.stderr ==
                 "mv: '#{unquote(same)}' and '#{unquote(same)}' are the same file\n"

        assert {:ok, "K\n", _fs} = read(bash, "/d/keep")
        assert {:ok, "A\n", _fs} = read(bash, "/a.md")
      end
    end

    # $ mv nope.md nope.md
    # mv: cannot stat 'nope.md': No such file or directory
    test "a missing source is reported before the two names are compared" do
      {result, _bash} = JustBash.exec(bash(), "mv /nope.md /nope.md")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot stat '/nope.md': No such file or directory\n"
    end
  end

  # A `..` component makes the same demand a trailing slash does: the kernel
  # can only walk up out of a directory. `FS.resolve_path/2` collapses it
  # lexically — `/f/..` becomes `/`, a directory whatever `/f` is — so the
  # demand is made about the last component the operand names outright.
  # GNU coreutils 9.11 / bash 5:
  #
  #     $ touch f/..         touch: cannot touch 'f/..': Not a directory
  #     $ touch nope/..      touch: cannot touch 'nope/..': No such file or directory
  #     $ touch f/x/..       touch: cannot touch 'f/x/..': Not a directory
  #     $ cp a.md f/..       cp: cannot stat 'f/..': Not a directory
  #     $ cp a.md nope/..    cp: cannot create regular file 'nope/..': No such file …
  #     $ mv a.md f/..       mv: cannot stat 'f/..': Not a directory
  #     $ mv d f/..          mv: cannot stat 'f/..': Not a directory
  #     $ echo hi > f/..     bash: f/..: Not a directory
  #     $ echo x | tee f/..  tee: f/..: Not a directory
  #     $ ln -s a.md f/..    ln: failed to create symbolic link 'f/..': Not a directory
  describe "a .. component demands a directory the way a trailing slash does" do
    for {command, message} <- [
          {"touch /f/..", "touch: cannot touch '/f/..': Not a directory\n"},
          {"touch /nope/..", "touch: cannot touch '/nope/..': No such file or directory\n"},
          {"touch /f/x/..", "touch: cannot touch '/f/x/..': Not a directory\n"},
          {"cp /a.md /f/..", "cp: cannot stat '/f/..': Not a directory\n"},
          {"cp /a.md /nope/..",
           "cp: cannot create regular file '/nope/..': No such file or directory\n"},
          {"mv /a.md /f/..", "mv: cannot stat '/f/..': Not a directory\n"},
          {"mv /d /f/..", "mv: cannot stat '/f/..': Not a directory\n"},
          {"echo hi > /f/..", "bash: /f/..: Not a directory\n"},
          {"echo hi | tee /f/..", "tee: /f/..: Not a directory\n"},
          {"ln -s /a.md /f/..", "ln: failed to create symbolic link '/f/..': Not a directory\n"}
        ] do
      test "`#{command}` is refused" do
        {result, bash} = JustBash.exec(bash(), unquote(command))

        assert result.exit_code == 1
        assert result.stderr == unquote(message)
        assert {:ok, "F\n", _fs} = read(bash, "/f")
        assert {:ok, "A\n", _fs} = read(bash, "/a.md")
        assert {:ok, "K\n", _fs} = read(bash, "/d/keep")
      end
    end

    # $ touch d/..   (exits 0: `d` really is a directory)
    test "a .. hanging off a real directory is accepted" do
      {result, _bash} = JustBash.exec(bash(), "touch /d/..")

      assert result.exit_code == 0
      assert result.stderr == ""
    end

    test "a bare .. is accepted: the cwd is a directory" do
      {result, _bash} = JustBash.exec(bash(), "cd /d && touch ..")

      assert result.exit_code == 0
      assert result.stderr == ""
    end
  end

  describe "output redirection to a target spelled as a directory" do
    # $ cat a.md > f/
    # bash: f/: Not a directory
    test "refuses to truncate a regular file" do
      {result, bash} = JustBash.exec(bash(), "cat /a.md > /f/")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: /f/: Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ echo hi >> f/
    # bash: f/: Not a directory
    test "refuses to append to a regular file" do
      {result, bash} = JustBash.exec(bash(), "echo hi >> /f/")

      assert result.exit_code == 1
      assert result.stderr == "bash: /f/: Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    test "refuses a trailing dot component too" do
      {result, bash} = JustBash.exec(bash(), "echo hi > /f/.")

      assert result.exit_code == 1
      assert result.stderr == "bash: /f/.: Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ echo hi > nope/
    # bash: nope/: No such file or directory
    test "will not create the file a slash promised would be a directory" do
      {result, bash} = JustBash.exec(bash(), "echo hi > /nope/")

      assert result.exit_code == 1
      assert result.stderr == "bash: /nope/: No such file or directory\n"
      refute exists?(bash, "/nope")
    end

    # $ echo hi > d/
    # bash: d/: Is a directory
    test "a directory is still a directory when spelled with the slash" do
      {result, _bash} = JustBash.exec(bash(), "echo hi > /d/")

      assert result.exit_code == 1
      assert result.stderr == "bash: /d/: Is a directory\n"
    end

    # $ echo hi 2> f/
    # bash: f/: Not a directory
    test "the stderr and combined forms are refused as well" do
      {stderr_redirect, bash} = JustBash.exec(bash(), "echo hi 2> /f/")
      assert stderr_redirect.exit_code == 1
      assert stderr_redirect.stderr == "bash: /f/: Not a directory\n"

      {combined, bash} = JustBash.exec(bash, "echo hi &> /f/")
      assert combined.exit_code == 1
      assert combined.stderr == "bash: /f/: Not a directory\n"

      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # A target that cannot be opened means the command never runs, so its
    # side effects never happen either.
    test "the command body does not run" do
      {result, bash} = JustBash.exec(bash(), "touch /made.md > /f/")

      assert result.exit_code == 1
      refute exists?(bash, "/made.md")
    end
  end

  describe "other commands that write to a named destination" do
    # $ echo hi | tee f/
    # tee: f/: Not a directory
    test "tee refuses the target but still passes stdin through" do
      {result, bash} = JustBash.exec(bash(), "echo hi | tee /f/")

      assert result.exit_code == 1
      assert result.stdout == "hi\n"
      assert result.stderr == "tee: /f/: Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ echo hi | tee nope/
    # tee: nope/: No such file or directory
    test "tee will not create the file a slash promised would be a directory" do
      {result, bash} = JustBash.exec(bash(), "echo hi | tee /nope/")

      assert result.exit_code == 1
      assert result.stderr == "tee: /nope/: No such file or directory\n"
      refute exists?(bash, "/nope")
    end

    # $ ln -s a.md f/
    # ln: failed to create symbolic link 'f/': Not a directory
    test "ln refuses to create a link at a non-directory" do
      {result, bash} = JustBash.exec(bash(), "ln -s /a.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "ln: failed to create symbolic link '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # `-f` unlinks the destination before linking, so the check has to come
    # first — the file it must not delete is the point. GNU lstats the
    # destination under `--force` and reports *that* failure instead:
    #
    #     $ ln -sf a.md f/  ln: failed to access 'f/': Not a directory
    #     $ ln -f  a.md f/  ln: failed to access 'f/': Not a directory
    test "ln -sf does not remove the file it may not link over" do
      {result, bash} = JustBash.exec(bash(), "ln -sf /a.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "ln: failed to access '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    test "ln -f reports the same failed access without -s" do
      {result, bash} = JustBash.exec(bash(), "ln -f /a.md /f/")

      assert result.exit_code == 1
      assert result.stderr == "ln: failed to access '/f/': Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    # $ ln -sf a.md nope/
    # ln: failed to create symbolic link 'nope/': No such file or directory
    #
    # Nothing is there to lstat, so `--force` has nothing to report and the
    # create it goes on to attempt is what fails.
    test "ln -sf onto a missing destination still reports the failed create" do
      {result, bash} = JustBash.exec(bash(), "ln -sf /a.md /nope/")

      assert result.exit_code == 1

      assert result.stderr ==
               "ln: failed to create symbolic link '/nope/': No such file or directory\n"

      refute exists?(bash, "/nope")
    end

    # $ sed -i s/F/Z/ f/
    # sed: can't read f/: Not a directory
    #
    # Real sed never opens `f/` — `open("f/")` is ENOTDIR — so the file it
    # would have edited is left alone. (Our diagnostics for sed operands are
    # spelled `sed: <operand>: <reason>` throughout, GNU's `can't read`
    # prefix predates this rule and is not what #58 is about.)
    test "sed -i refuses to edit through a destination spelled as a directory" do
      {result, bash} = JustBash.exec(bash(), "sed -i 's/F/Z/' /f/")

      assert result.exit_code == 1
      assert result.stderr == "sed: /f/: Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    test "sed -i refuses a trailing dot component too" do
      {result, bash} = JustBash.exec(bash(), "sed -i 's/F/Z/' /f/.")

      assert result.exit_code == 1
      assert result.stderr == "sed: /f/.: Not a directory\n"
      assert {:ok, "F\n", _fs} = read(bash, "/f")
    end

    test "sed -i will not create the file a slash promised would be a directory" do
      {result, bash} = JustBash.exec(bash(), "sed -i 's/F/Z/' /nope/")

      assert result.exit_code == 1
      assert result.stderr == "sed: /nope/: No such file or directory\n"
      refute exists?(bash, "/nope")
    end

    test "sed -i still edits a file named without the slash" do
      {result, bash} = JustBash.exec(bash(), "sed -i 's/F/Z/' /f")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert {:ok, "Z\n", _fs} = read(bash, "/f")
    end

    # $ touch f/
    # touch: cannot touch 'f/': Not a directory
    test "touch refuses a non-directory spelled as one" do
      {result, _bash} = JustBash.exec(bash(), "touch /f/")

      assert result.exit_code == 1
      assert result.stderr == "touch: cannot touch '/f/': Not a directory\n"
    end

    # $ touch nope/
    # touch: cannot touch 'nope/': No such file or directory
    test "touch will not create the file a slash promised would be a directory" do
      {result, bash} = JustBash.exec(bash(), "touch /nope/")

      assert result.exit_code == 1
      assert result.stderr == "touch: cannot touch '/nope/': No such file or directory\n"
      refute exists?(bash, "/nope")
    end

    # $ touch d/   (exit 0: the promise holds)
    test "touch accepts a real directory" do
      {result, _bash} = JustBash.exec(bash(), "touch /d/")

      assert result.exit_code == 0
      assert result.stderr == ""
    end
  end

  describe "FS.directory_spelling?/1" do
    test "a trailing slash and the dot components it implies demand a directory" do
      assert FS.directory_spelling?("/f/")
      assert FS.directory_spelling?("f/")
      assert FS.directory_spelling?("/f/.")
      assert FS.directory_spelling?("/f/..")
      assert FS.directory_spelling?(".")
      assert FS.directory_spelling?("..")
      assert FS.directory_spelling?("/")
    end

    test "a plain path demands nothing" do
      refute FS.directory_spelling?("/f")
      refute FS.directory_spelling?("f")
      refute FS.directory_spelling?("/a/b.md")
      refute FS.directory_spelling?("..f")
      refute FS.directory_spelling?("/f/...")
    end

    # An empty operand names nothing at all, which is a different complaint
    # from the one this rule makes.
    test "an empty path demands nothing" do
      refute FS.directory_spelling?("")
    end
  end

  describe "FS.check_directory_spelling/3" do
    test "passes a path that makes no demand" do
      assert {:ok, _fs} = FS.check_directory_spelling(fs(), "/", "/f")
    end

    test "passes a directory" do
      assert {:ok, _fs} = FS.check_directory_spelling(fs(), "/", "/d/")
    end

    test "returns :enotdir for a non-directory, naming the operand as spelled" do
      assert {:error, %VFS.Error{kind: :enotdir, path: "/f/"}} =
               FS.check_directory_spelling(fs(), "/", "/f/")
    end

    test "returns the error stat gave for a path that is not there" do
      assert {:error, %VFS.Error{kind: :enoent}} =
               FS.check_directory_spelling(fs(), "/", "/nope/")
    end

    test "resolves a relative spelling against the base" do
      assert {:ok, _fs} = FS.check_directory_spelling(fs(), "/d", "../d/")

      assert {:error, %VFS.Error{kind: :enotdir, path: "../f/"}} =
               FS.check_directory_spelling(fs(), "/d", "../f/")
    end

    # `resolve_path/2` collapses `..` lexically, so the demand is made about
    # the last component the spelling names outright — `/f` for `/f/..`, not
    # the `/` that `/f/..` resolves to.
    test "a trailing .. demands the component it hangs off, not where it lands" do
      assert {:error, %VFS.Error{kind: :enotdir, path: "/f/.."}} =
               FS.check_directory_spelling(fs(), "/", "/f/..")

      assert {:error, %VFS.Error{kind: :enoent}} =
               FS.check_directory_spelling(fs(), "/", "/nope/..")

      assert {:ok, _fs} = FS.check_directory_spelling(fs(), "/", "/d/..")
      assert {:ok, _fs} = FS.check_directory_spelling(fs(), "/d", "..")
      assert {:ok, _fs} = FS.check_directory_spelling(fs(), "/d", ".")
    end
  end
end
