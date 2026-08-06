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
  """
  use ExUnit.Case, async: true

  alias JustBash.Test.FailingBackend

  # Commands that read a file's *contents*. Every one of these can hit all four
  # kinds, including :eisdir — reading a directory is an error.
  #
  # `PATH` is the operand under test; `MSG` is the strerror text for the kind.
  @content_readers [
    {"cat PATH", :stderr, "cat: PATH: MSG\n"},
    {"wc PATH", :stderr, "wc: PATH: MSG\n"},
    {"head PATH", :stderr, "head: cannot open 'PATH' for reading: MSG\n"},
    {"tail PATH", :stderr, "tail: cannot open 'PATH' for reading: MSG\n"},
    {"od PATH", :stderr, "od: PATH: MSG\n"},
    {"xxd PATH", :stderr, "xxd: PATH: MSG\n"},
    {"base64 PATH", :stderr, "base64: PATH: MSG\n"},
    {"tac PATH", :stderr, "tac: PATH: MSG\n"},
    {"rev PATH", :stderr, "rev: PATH: MSG\n"},
    {"nl PATH", :stderr, "nl: PATH: MSG\n"},
    {"fold PATH", :stderr, "fold: PATH: MSG\n"},
    {"expand PATH", :stderr, "expand: PATH: MSG\n"},
    {"paste PATH", :stderr, "paste: PATH: MSG\n"},
    {"comm PATH PATH", :stderr, "comm: PATH: MSG\n"},
    {"jq . PATH", :stderr, "jq: PATH: MSG\n"},
    {"awk '{print}' PATH", :stderr, "awk: PATH: MSG\n"},
    {"sed -n p PATH", :stderr, "sed: PATH: MSG\n"},
    {"sed -i s/a/b/ PATH", :stderr, "sed: PATH: MSG\n"},
    {"sha256sum PATH", :stderr, "sha256sum: PATH: MSG\n"},
    {"shasum PATH", :stderr, "shasum: PATH: MSG\n"},
    {"diff PATH PATH", :stderr, "diff: PATH: MSG\n"},
    {"source PATH", :stderr, "bash: source: PATH: MSG\n"},
    # md5sum writes its diagnostic to stdout. That is a separate bug from the
    # message text, so it is recorded here rather than quietly corrected.
    {"md5sum PATH", :stdout, "md5sum: PATH: MSG\n"}
  ]

  # Commands that only inspect metadata. A directory is a perfectly good answer
  # for these, so :eisdir is not among the kinds they can surface.
  @metadata_readers [
    {"stat PATH", :stderr, "stat: cannot stat 'PATH': MSG\n"},
    {"chmod 644 PATH", :stderr, "chmod: cannot access 'PATH': MSG\n"},
    {"chown u PATH", :stderr, "chown: cannot access 'PATH': MSG\n"},
    {"realpath PATH", :stderr, "realpath: PATH: MSG\n"},
    {"du PATH", :stderr, "du: cannot access 'PATH': MSG\n"},
    {"find PATH", :stderr, "find: PATH: MSG\n"},
    {"tree PATH", :stderr, "tree: PATH: MSG\n"},
    {"ls PATH", :stderr, "ls: cannot access 'PATH': MSG\n"},
    {"rm PATH", :stderr, "rm: cannot remove 'PATH': MSG\n"},
    {"cp PATH /dest", :stderr, "cp: cannot stat 'PATH': MSG\n"},
    {"file PATH", :stdout, "PATH: cannot open (MSG)\n"}
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
    for {script, stream, template} <- @content_readers,
        kind <- [:enoent, :enotdir, :eisdir, :eacces] do
      test "#{script} names #{kind} rather than guessing" do
        kind = unquote(kind)
        {result, _bash} = JustBash.exec(sandbox(kind), fill(unquote(script), kind))

        assert Map.fetch!(result, unquote(stream)) == fill(unquote(template), kind)
        assert result.exit_code != 0
      end
    end

    for {script, stream, template} <- @metadata_readers,
        kind <- [:enoent, :enotdir, :eacces] do
      test "#{script} names #{kind} rather than guessing" do
        kind = unquote(kind)
        {result, _bash} = JustBash.exec(sandbox(kind), fill(unquote(script), kind))

        assert Map.fetch!(result, unquote(stream)) == fill(unquote(template), kind)
        assert result.exit_code != 0
      end
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
