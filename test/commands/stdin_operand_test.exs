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
      (`classify_redirection/3`). The filesystem layer now services the same
      path as a special file, so `cmd < /dev/null` and `cmd /dev/null` agree.

  The `-` rows are checked against the same command reading a real file with
  the same bytes, rather than against a literal transcript: the invariant is
  that the operand names a source, not that `nl` pads to six columns.
  """
  use ExUnit.Case, async: true

  alias JustBash.Commands.Registry

  @stdin "b\na\nb\n"

  # The bytes of the *other* operand in the two-operand rows, distinct from
  # `@stdin` so that dropping either one is visible.
  @other "d\nc\nd\n"

  # `jq` is the one row whose input has to be a JSON document rather than
  # arbitrary lines, so it names its own — both of them.
  @json "{\"k\":1}\n"
  @json_other "{\"k\":2}\n"

  # Every command whose file operand GNU reads as stdin when it is `-`, with
  # the rest of the invocation it needs to do anything. FILE is the operand
  # under test; a row may carry the stdin it needs, the name the command shows
  # for that operand when it is not the literal `-`, and the bytes of the
  # second operand in the two-operand runs.
  @dash_operand [
    {"jq . FILE", @json, "-", @json_other},
    {"file FILE", @stdin, "/dev/stdin", @other},
    {"head FILE", @stdin, "standard input", @other},
    {"tail FILE", @stdin, "standard input", @other},
    {"grep b FILE", @stdin, "(standard input)", @other},
    "cat FILE",
    "tac FILE",
    "wc -l FILE",
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
          {script, input, shown, other} -> {script, input, shown, other}
          script -> {script, @stdin, "-", @other}
        end)

  describe "the registry is fully classified" do
    test "every command is either a `-`-reads-stdin command or explicitly not" do
      named = Enum.map(@rows, fn {script, _, _, _} -> script |> String.split(" ") |> hd() end)
      classified = MapSet.new(named ++ @no_dash_operand)

      assert MapSet.new(Registry.list()) == classified
    end
  end

  describe "`-` names stdin, not a path" do
    for {script, input, shown, _other} <- @rows do
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

  describe "`-` is still stdin when it shares the command line with a file" do
    # The rows above only ever build a single-operand invocation, and that is
    # blind to the bug that mattered: a parser that deletes `-` from the
    # operand list — `Enum.reject(args, &String.starts_with?(&1, "-"))` — still
    # looks correct there, because deleting the only operand leaves the command
    # falling back to stdin for a second reason. It is only with a file beside
    # it that the deletion shows up, as a missing operand or as `-` reaching
    # the filesystem.
    #
    # The reference run puts `/s` — a real file holding exactly the stdin bytes
    # — in the `-` slot, so a command that reads only its first operand, or
    # only its last, compares equal to itself. What is under test is the
    # classification of `-`, not how many operands the command supports.
    for {script, input, shown, other} <- @rows do
      test "#{script}: `- FILE` and `FILE -` name stdin in either position" do
        {script, input, shown, other} =
          {unquote(script), unquote(input), unquote(shown), unquote(other)}

        for {dash, ref} <- [{{"-", "/f"}, {"/s", "/f"}}, {{"/f", "-"}, {"/f", "/s"}}] do
          {piped, _bash} = run(script, dash, input, other)
          {from_file, _bash} = run(script, ref, input, other)

          assert piped.exit_code == from_file.exit_code
          assert piped.stderr == String.replace(from_file.stderr, "/s", shown)
          assert piped.stdout == String.replace(from_file.stdout, "/s", shown)
        end
      end
    end

    # The matrix above compares `-` against a file and so cannot see this:
    # `tac a b` is `tac a; tac b`, not `cat a b | tac`. GNU reverses each
    # operand's lines on its own and writes the operands in the order given —
    # `gtac - b` with `1\n2\n` on stdin prints `2 1 4 3`, not `4 3 2 1`.
    test "tac reverses each operand on its own, in operand order" do
      bash = JustBash.new(files: %{"/a" => "1\n2\n", "/b" => "3\n4\n"})
      piped = "printf '1\\n2\\n' | "

      assert {%{stdout: "2\n1\n4\n3\n"}, _} = JustBash.exec(bash, "tac /a /b")
      assert {%{stdout: "4\n3\n2\n1\n"}, _} = JustBash.exec(bash, "tac /b /a")
      assert {%{stdout: "2\n1\n4\n3\n"}, _} = JustBash.exec(bash, piped <> "tac - /b")
      assert {%{stdout: "4\n3\n2\n1\n"}, _} = JustBash.exec(bash, piped <> "tac /b -")
    end

    # `tac n a` is still `tac n; tac a`. The unterminated last record of n
    # stays without a separator, so it glues to a's first reversed record.
    # Bytes pinned against /usr/bin/tac on this host.
    test "tac two-file unterminated last line matches GNU record split" do
      bash = JustBash.new(files: %{"/n" => "1\n2", "/a" => "1\n2\n"})

      assert {%{stdout: "21\n2\n1\n"}, _} = JustBash.exec(bash, "tac /n /a")
      assert {%{stdout: "2\n1\n21\n"}, _} = JustBash.exec(bash, "tac /a /n")
    end

    # GNU rev reverses each operand on its own and concatenates. Concatenating
    # first then reversing glues the unterminated last line of n to the first
    # line of a and reverses them as one record.
    test "rev reverses each operand on its own, including unterminated last lines" do
      bash = JustBash.new(files: %{"/n" => "ab\ncd", "/a" => "ef\ngh\n"})

      assert {%{stdout: "ba\ndcfe\nhg\n"}, _} = JustBash.exec(bash, "rev /n /a")
      assert {%{stdout: "fe\nhg\nba\ndc"}, _} = JustBash.exec(bash, "rev /a /n")
    end

    test "an operand after `--` is a path, dash and all" do
      bash = JustBash.new(files: %{"/-f" => "12\n34\n"})

      assert {%{stdout: "34\n12\n", stderr: "", exit_code: 0}, _} =
               JustBash.exec(bash, "cd /; tac -- -f")

      assert {%{stdout: "21\n43\n", stderr: "", exit_code: 0}, _} =
               JustBash.exec(bash, "cd /; rev -- -f")
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
      # `> /dev/null` discards; `< /dev/null` has to be the same set of paths,
      # or the two disagree about what a path even is. The filesystem layer
      # now holds that set, so the operand `cat /dev/null` agrees too.
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

  # In the two-operand runs the two operands hold different bytes, so dropping
  # either one is visible, and /s holds the stdin bytes so that it stands in
  # for `-`.
  defp run(script, {first, second}, input, other) do
    bash = JustBash.new(files: %{"/f" => other, "/s" => input})
    JustBash.exec(bash, "printf #{inspect(input)} | " <> invocation(script, first, second))
  end

  # `comm FILE FILE` and `diff FILE FILE` already name two operands; every
  # other row names one and gets a second appended.
  defp invocation(script, first, second) do
    case String.split(script, "FILE", parts: 3) do
      [pre, post] -> pre <> first <> " " <> second <> post
      [pre, mid, post] -> pre <> first <> mid <> second <> post
    end
  end
end
