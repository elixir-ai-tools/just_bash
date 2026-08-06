defmodule JustBash.Commands.StdinOperandTest do
  @moduledoc """
  `-` as a file operand names stdin, and `/dev/null` reads as empty.

  The #70 sweep taught the read paths to report the read they could not do.
  That is only correct for operands that are really paths. Two classes of
  operand are not:

    * `-`, which POSIX and GNU read as standard input. `echo x | sort -` used
      to exit 0 with nothing, which is the silent-success class #70 exists to
      remove; the sweep turned it into `sort: cannot read: -` and a non-zero
      exit, which is worse — a pipeline under `set -e` now dies.

    * `/dev/null`, which the write side of redirection already special-cases
      (`classify_redirection/3`) but the read side did not. `cmd < /dev/null`
      is the standard way to close a command's stdin, and it started aborting
      the command.

  The `-` rows are checked against the same command reading a real file with
  the same bytes, rather than against a literal transcript: the invariant is
  that the operand names a source, not that `nl` pads to six columns.
  """
  use ExUnit.Case, async: true

  alias JustBash.Commands.Registry

  @stdin "b\na\nb\n"

  # `jq` is the one row whose input has to be a JSON document rather than
  # arbitrary lines, so it names its own.
  @json "{\"k\":1}\n"

  # Every command whose file operand GNU reads as stdin when it is `-`, with
  # the rest of the invocation it needs to do anything. FILE is the operand
  # under test; a row may carry the stdin it needs, and the name the command
  # shows for that operand when it is not the literal `-`.
  @dash_operand [
    {"jq . FILE", @json, "-"},
    {"file FILE", @stdin, "/dev/stdin"},
    "cat FILE",
    "tac FILE",
    "head FILE",
    "tail FILE",
    "wc -l FILE",
    "grep b FILE",
    "sort FILE",
    "uniq FILE",
    "cut -c1 FILE",
    "nl FILE",
    "rev FILE",
    "fold -w1 FILE",
    "expand FILE",
    "paste FILE",
    "comm FILE FILE",
    "base64 FILE",
    "md5sum FILE",
    "sha256sum FILE",
    "shasum FILE",
    "od -c FILE",
    "xxd FILE",
    "diff FILE FILE",
    "sed -n p FILE",
    "awk '{print}' FILE"
  ]

  # The rest of the registry. `-` is not stdin for these: either they take no
  # file operand at all, or GNU treats `-` as an ordinary name (`tee -` writes
  # a file called `-`; `rm -` removes one). Kept explicit so that a command
  # added to the registry has to be classified rather than silently skipped.
  @no_dash_operand ~w(
    echo true : false pwd cd ls mkdir rm touch export unset test [ cp mv
    printf basename dirname read seq tr date sleep exit tee env printenv
    which ln readlink hostname stat du tree find xargs curl set source .
    markdown md local declare typeset break continue shift return getopts
    trap eval command uname chmod chown wget mktemp whoami id realpath
    nproc arch yes type
  )

  @rows Enum.map(@dash_operand, fn
          {script, input, shown} -> {script, input, shown}
          script -> {script, @stdin, "-"}
        end)

  describe "the registry is fully classified" do
    test "every command is either a `-`-reads-stdin command or explicitly not" do
      named = Enum.map(@rows, fn {script, _, _} -> script |> String.split(" ") |> hd() end)
      classified = MapSet.new(named ++ @no_dash_operand)

      assert MapSet.new(Registry.list()) == classified
    end
  end

  describe "`-` names stdin, not a path" do
    for {script, input, shown} <- @rows do
      test "#{script} reads stdin" do
        {script, input, shown} = {unquote(script), unquote(input), unquote(shown)}
        dash = String.replace(script, "FILE", "-")
        file = String.replace(script, "FILE", "/f")

        {piped, _bash} = JustBash.exec(sandbox(input), "printf #{inspect(input)} | " <> dash)
        {from_file, _bash} = JustBash.exec(sandbox(input), file)

        assert piped.stderr == ""
        assert piped.exit_code == from_file.exit_code
        assert piped.stdout == String.replace(from_file.stdout, "/f", shown)
      end
    end

    # GNU does not agree with itself about what to call stdin in a per-operand
    # label, so each of these is its own transcript.
    test "grep labels the operand (standard input)" do
      {result, _bash} = JustBash.exec(sandbox(), "printf 'b\\n' | grep b - /f")

      assert result.stdout == "(standard input):b\n/f:b\n/f:b\n"
      assert result.exit_code == 0
    end

    test "head labels the operand standard input" do
      {result, _bash} = JustBash.exec(sandbox(), "printf 'z\\n' | head -1 - /f")

      assert result.stdout =~ "==> standard input <==\nz\n"
      assert result.stdout =~ "==> /f <==\nb\n"
    end

    test "wc labels the operand -" do
      {result, _bash} = JustBash.exec(sandbox(), "printf 'z\\n' | wc -l - /f")

      assert result.stdout == "      1 -\n      3 /f\n      4 total\n"
    end

    test "a pipeline into `sort -` under `set -e` survives" do
      {result, _bash} = JustBash.exec(sandbox(), "set -e; printf 'b\\na\\n' | sort -; echo done")

      assert result.stdout == "a\nb\ndone\n"
      assert result.stderr == ""
      assert result.exit_code == 0
    end

    test "a real path called -x is still a path" do
      {result, _bash} = JustBash.exec(sandbox(), "sort -x")

      assert result.stderr != ""
      assert result.exit_code != 0
    end
  end

  describe "`< /dev/null` closes stdin" do
    test "cat reads nothing and exits 0" do
      {result, _bash} = JustBash.exec(sandbox(), "cat < /dev/null; echo rc=$?")

      assert result.stdout == "rc=0\n"
      assert result.stderr == ""
    end

    test "read sees end of input and exits 1, with no diagnostic" do
      {result, _bash} = JustBash.exec(sandbox(), "read x < /dev/null; echo rc=$?")

      assert result.stdout == "rc=1\n"
      assert result.stderr == ""
    end

    test "wc -l counts nothing" do
      {result, _bash} = JustBash.exec(sandbox(), "wc -l < /dev/null")

      assert result.stdout == "0\n"
      assert result.stderr == ""
      assert result.exit_code == 0
    end

    test "the read side agrees with the write side about which paths are special" do
      # `> /dev/null` discards without touching the filesystem; `< /dev/null`
      # has to be the same set of paths, or the two disagree about what a path
      # even is.
      {result, _bash} =
        JustBash.exec(sandbox(), "echo hi > /dev/null; echo rc=$?; cat < /dev/null; echo rc=$?")

      assert result.stdout == "rc=0\nrc=0\n"
      assert result.stderr == ""
    end

    test "a path merely containing dev/null is still a path" do
      {result, _bash} = JustBash.exec(sandbox(), "cat < /nope/dev/null")

      assert result.stderr == "bash: /nope/dev/null: No such file or directory\n"
      assert result.exit_code == 1
    end
  end

  # /f holds exactly the bytes the pipeline feeds in, so `cmd -` and `cmd /f`
  # differ only in where the command looked for them.
  defp sandbox(content \\ @stdin), do: JustBash.new(files: %{"/f" => content})
end
