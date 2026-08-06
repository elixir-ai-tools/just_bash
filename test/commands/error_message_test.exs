defmodule JustBash.Commands.ErrorMessageTest do
  @moduledoc """
  The strerror sweep from #70: 33 command modules spelled every filesystem
  failure "No such file or directory", because they matched `{:error, _}` and
  threw the kind away. `stat /f/x` on a regular-file `/f` claimed the path did
  not exist when it exists and its parent is not a directory.

  The cases below are the cross product of the commands that touch the
  filesystem and the error kinds a path can fail with, enumerated rather than
  written one at a time — the point of #70 is that a matrix nobody wrote by
  hand is where the divergences hide.

  Operand arity is part of that cross product. `head`, `tail` and `wc` each
  have a single-file arm and a reduce over several files, and `sha256sum` and
  `shasum` have a third arm behind `-c`; with every row pinned to one operand,
  five of the sites this sweep exists to fix could be reverted with the suite
  still green. Rows that name two operands, or a checksum file, are there to
  reach them.
  """
  use ExUnit.Case, async: true

  alias JustBash.Test.FailingBackend

  # Reading a file's *contents* can hit all four kinds, including :eisdir —
  # reading a directory is an error.
  @read_kinds [:enoent, :enotdir, :eisdir, :eacces]

  # A directory is a perfectly good answer for a command that only inspects
  # metadata, so :eisdir is not among the kinds it can surface. It is also not
  # among the kinds that can reach a template chosen at `open(2)` time — GNU
  # head/tail/tac open a directory successfully and fail at `read(2)`, which
  # gets its own wording.
  @stat_kinds [:enoent, :enotdir, :eacces]

  # Each row is an invocation, the kinds it covers, the stream the diagnostic
  # belongs on, and the template. `PATH` is the operand under test; `MSG` is
  # the strerror text for the kind.
  @matrix [
    {"cat PATH", @read_kinds, :stderr, "cat: PATH: MSG\n"},
    {"wc PATH", @read_kinds, :stderr, "wc: PATH: MSG\n"},
    {"head PATH", @stat_kinds, :stderr, "head: cannot open 'PATH' for reading: MSG\n"},
    {"head PATH", [:eisdir], :stderr, "head: error reading 'PATH': MSG\n"},
    {"tail PATH", @stat_kinds, :stderr, "tail: cannot open 'PATH' for reading: MSG\n"},
    {"tail PATH", [:eisdir], :stderr, "tail: error reading 'PATH': MSG\n"},
    {"od PATH", @read_kinds, :stderr, "od: PATH: MSG\n"},
    {"xxd PATH", @read_kinds, :stderr, "xxd: PATH: MSG\n"},
    {"base64 PATH", @read_kinds, :stderr, "base64: PATH: MSG\n"},
    {"tac PATH", @stat_kinds, :stderr, "tac: failed to open 'PATH' for reading: MSG\n"},
    {"tac PATH", [:eisdir], :stderr, "tac: PATH: read error: MSG\n"},
    {"rev PATH", @read_kinds, :stderr, "rev: PATH: MSG\n"},
    {"nl PATH", @read_kinds, :stderr, "nl: PATH: MSG\n"},
    {"fold PATH", @read_kinds, :stderr, "fold: PATH: MSG\n"},
    {"expand PATH", @read_kinds, :stderr, "expand: PATH: MSG\n"},
    {"paste PATH", @read_kinds, :stderr, "paste: PATH: MSG\n"},
    {"comm PATH PATH", @read_kinds, :stderr, "comm: PATH: MSG\n"},
    {"jq . PATH", @read_kinds, :stderr, "jq: PATH: MSG\n"},
    {"awk '{print}' PATH", @read_kinds, :stderr, "awk: PATH: MSG\n"},
    {"sed -n p PATH", @read_kinds, :stderr, "sed: PATH: MSG\n"},
    {"sed -i s/a/b/ PATH", @read_kinds, :stderr, "sed: PATH: MSG\n"},
    {"sha256sum PATH", @read_kinds, :stderr, "sha256sum: PATH: MSG\n"},
    {"shasum PATH", @read_kinds, :stderr, "shasum: PATH: MSG\n"},
    {"diff PATH PATH", @read_kinds, :stderr, "diff: PATH: MSG\n"},
    {"source PATH", @read_kinds, :stderr, "bash: source: PATH: MSG\n"},
    {"md5sum PATH", @read_kinds, :stderr, "md5sum: PATH: MSG\n"},
    {"stat PATH", @stat_kinds, :stderr, "stat: cannot stat 'PATH': MSG\n"},
    {"chmod 644 PATH", @stat_kinds, :stderr, "chmod: cannot access 'PATH': MSG\n"},
    {"chown u PATH", @stat_kinds, :stderr, "chown: cannot access 'PATH': MSG\n"},
    # Without -e, realpath only requires the *parent* components to exist, so
    # :enoent on the final component is not an error at all — see below.
    {"realpath PATH", [:enotdir, :eacces], :stderr, "realpath: PATH: MSG\n"},
    {"realpath -e PATH", @stat_kinds, :stderr, "realpath: PATH: MSG\n"},
    {"du PATH", @stat_kinds, :stderr, "du: cannot access 'PATH': MSG\n"},
    {"find PATH", @stat_kinds, :stderr, "find: PATH: MSG\n"},
    {"tree PATH", @stat_kinds, :stderr, "tree: PATH: MSG\n"},
    {"ls PATH", @stat_kinds, :stderr, "ls: cannot access 'PATH': MSG\n"},
    {"rm PATH", @stat_kinds, :stderr, "rm: cannot remove 'PATH': MSG\n"},
    {"cp PATH /dest", @stat_kinds, :stderr, "cp: cannot stat 'PATH': MSG\n"},
    {"file PATH", @stat_kinds, :stdout, "PATH: cannot open (MSG)\n"},
    # -b suppresses the filename prefix, not the reason.
    {"file -b PATH", @stat_kinds, :stdout, "cannot open (MSG)\n"},

    # Operand arity is an axis of this matrix, not a constant. head, tail and
    # wc each have a single-file arm and a reduce over several files, and the
    # sweep changed both; a one-operand invocation can never reach the second.
    {"head PATH /f", @stat_kinds, :stderr, "head: cannot open 'PATH' for reading: MSG\n"},
    {"head PATH /f", [:eisdir], :stderr, "head: error reading 'PATH': MSG\n"},
    {"tail PATH /f", @stat_kinds, :stderr, "tail: cannot open 'PATH' for reading: MSG\n"},
    {"tail PATH /f", [:eisdir], :stderr, "tail: error reading 'PATH': MSG\n"},
    {"wc PATH /f", @read_kinds, :stderr, "wc: PATH: MSG\n"},

    # -c is a third arm again: one site for the checksum file itself, another
    # for each target it names.
    {"sha256sum -c PATH", @read_kinds, :stderr, "sha256sum: PATH: MSG\n"},
    {"shasum -c PATH", @read_kinds, :stderr, "shasum: PATH: MSG\n"},
    {"echo '0  PATH' > /sums; sha256sum -c /sums", @read_kinds, :stderr,
     "sha256sum: PATH: MSG\n"},
    {"echo '0  PATH' > /sums; shasum -c /sums", @read_kinds, :stderr, "shasum: PATH: MSG\n"},

    # These five printed nothing at all, which is why grepping for the wrong
    # message did not reach them. `sort report.txt | head -5` against a
    # mistyped path is an empty exit-0 result an agent cannot tell from an
    # empty file.
    {"sort PATH", @stat_kinds, :stderr, "sort: cannot read: PATH: MSG\n"},
    {"sort PATH", [:eisdir], :stderr, "sort: read failed: PATH: MSG\n"},
    {"cut -f1 PATH", @read_kinds, :stderr, "cut: PATH: MSG\n"},
    {"cut -f1 PATH /f", @read_kinds, :stderr, "cut: PATH: MSG\n"},
    {"uniq PATH", @stat_kinds, :stderr, "uniq: PATH: MSG\n"},
    {"uniq PATH", [:eisdir], :stderr, "uniq: error reading 'PATH': MSG\n"},
    {"grep x PATH", @read_kinds, :stderr, "grep: PATH: MSG\n"},
    {"grep hi PATH /f", @read_kinds, :stderr, "grep: PATH: MSG\n"},

    # `<` is opened by the shell, so the shell reports it and the command
    # never runs. :eisdir is absent because `open(2)` on a directory succeeds
    # — bash runs the command and the command fails on read, with its own name
    # in the message, which this model does not reach.
    {"cat < PATH", @stat_kinds, :stderr, "bash: PATH: MSG\n"},
    {"wc -l < PATH", @stat_kinds, :stderr, "bash: PATH: MSG\n"}
  ]

  @strerror %{
    enoent: "No such file or directory",
    enotdir: "Not a directory",
    eisdir: "Is a directory",
    eacces: "Permission denied"
  }

  # /f is a regular file, so /f/x names a path whose parent component is not a
  # directory; /d is a directory, so reading it is :eisdir. The in-memory
  # backend has no permission model, so :eacces comes from a mount that refuses
  # everything — the only way to reach the kind at all.
  @files %{"/f" => "hi\n", "/d/inner" => "x\n"}

  defp sandbox(:eacces) do
    JustBash.new(files: @files)
    |> JustBash.mount("/mnt", %FailingBackend{kind: :eacces})
  end

  defp sandbox(_kind), do: JustBash.new(files: @files)

  defp path(:enoent), do: "/nope"
  defp path(:enotdir), do: "/f/x"
  defp path(:eisdir), do: "/d"
  defp path(:eacces), do: "/mnt/f"

  defp fill(template, kind) do
    template
    |> String.replace("PATH", path(kind))
    |> String.replace("MSG", Map.fetch!(@strerror, kind))
  end

  describe "the strerror matrix" do
    for {script, kinds, stream, template} <- @matrix, kind <- kinds do
      test "#{script} names #{kind} rather than guessing" do
        kind = unquote(kind)
        {result, _bash} = JustBash.exec(sandbox(kind), fill(unquote(script), kind))

        assert Map.fetch!(result, unquote(stream)) == fill(unquote(template), kind)
        assert result.exit_code != 0
      end
    end
  end

  describe "a diagnostic never lands in a data stream" do
    test "md5sum keeps the checksum stream free of its own error" do
      # `md5sum a b > sums.txt` has to produce a checksum file, not a checksum
      # file with a diagnostic wedged into it as a malformed line.
      {result, _bash} = JustBash.exec(sandbox(:enoent), "md5sum /f /nope")

      assert result.stdout == "764efa883dda1e11db47671c4a3bbd9e  /f\n"
      assert result.stderr == "md5sum: /nope: No such file or directory\n"
      assert result.exit_code == 1
    end

    test "md5sum's error is silenced by 2>/dev/null" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "md5sum /nope 2>/dev/null")

      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "md5sum -c reports a checksum file it cannot read" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "md5sum -c /nope")

      assert result.stdout == ""
      assert result.stderr == "md5sum: /nope: No such file or directory\n"
      assert result.exit_code == 1
    end
  end

  describe "a read that fails is never mistaken for an empty file" do
    test "sort exits 2 the way GNU sort does" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "sort /nope")

      assert result.exit_code == 2
    end

    test "cut keeps the files it could read and still exits 1" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "cut -f1 /f /nope")

      assert result.stdout == "hi\n"
      assert result.exit_code == 1
    end

    test "grep exits 2 on a read failure even when another file matched" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "grep hi /f /nope")

      assert result.stdout == "/f:hi\n"
      assert result.exit_code == 2
    end

    test "grep -q still exits 0 when a line was selected" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "grep -q hi /f /nope")

      assert result.stdout == ""
      assert result.stderr == "grep: /nope: No such file or directory\n"
      assert result.exit_code == 0
    end

    test "a failed < redirect stops the command from running" do
      # `wc -l < /nope` used to print a fabricated 0 — the sharpest form of the
      # bug, because the number looks like an answer.
      {result, _bash} = JustBash.exec(sandbox(:enoent), "wc -l < /nope")

      assert result.stdout == ""
      assert result.stderr == "bash: /nope: No such file or directory\n"
      assert result.exit_code == 1
    end

    test "a loop redirected from a file it cannot open does not run either" do
      {result, _bash} =
        JustBash.exec(sandbox(:enoent), "while read line; do echo ran; done < /nope")

      assert result.stdout == ""
      assert result.stderr == "bash: /nope: No such file or directory\n"
      assert result.exit_code == 1
    end

    test "a heredoc is unaffected" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "cat <<< hello")

      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end
  end

  # Verified against coreutils 9.x: `grealpath nope` -> rc=0 and the
  # canonicalised path; `grealpath nope/deep/x` -> rc=1. The last component is
  # allowed to be missing; everything before it has to be a directory.
  describe "realpath without -e" do
    test "canonicalises a missing final component and exits 0" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "realpath /nope")

      assert result.stdout == "/nope\n"
      assert result.stderr == ""
      assert result.exit_code == 0
    end

    test "errors when an intermediate component is missing" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "realpath /nope/deep/x")

      assert result.stderr == "realpath: /nope/deep/x: No such file or directory\n"
      assert result.exit_code == 1
    end

    test "errors when the parent component is not a directory" do
      {result, _bash} = JustBash.exec(sandbox(:enotdir), "realpath /f/x")

      assert result.stderr == "realpath: /f/x: Not a directory\n"
      assert result.exit_code == 1
    end

    test "-m accepts a missing intermediate component too" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "realpath -m /nope/deep/x")

      assert result.stdout == "/nope/deep/x\n"
      assert result.exit_code == 0
    end

    test "-e still requires the whole path to exist" do
      {result, _bash} = JustBash.exec(sandbox(:enoent), "realpath -e /nope")

      assert result.stderr == "realpath: /nope: No such file or directory\n"
      assert result.exit_code == 1
    end
  end

  describe "JustBash.exec_file/2" do
    test "names the kind when the script path is not readable" do
      bash = JustBash.new(files: @files)

      assert {%{stderr: "/f/x: Not a directory\n", exit_code: 1}, _bash} =
               JustBash.exec_file(bash, "/f/x")
    end
  end
end
