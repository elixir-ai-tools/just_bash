defmodule JustBash.RedirectPreflightTest do
  @moduledoc """
  Regression tests for issue #59: a command whose redirect cannot be opened
  must not run at all.

  bash opens every redirect target before it forks the command, so the
  command's side effects — the directory `mkdir` would have made, the file
  `touch` would have created — never happen when the open fails. Suppressing
  the command's *output* is not enough; issue #53 covered that half, and
  `not_a_directory_test.exs` holds those expectations.

  Opening the target early is also what truncates it, and what fixes when a
  command substitution in the target runs. Every expectation below was
  checked against GNU bash 3.2.57.
  """
  use ExUnit.Case, async: true

  alias JustBash.FS

  # /m/j is a regular file, so /m/j/x can never be opened: POSIX resolution
  # requires every non-final component to be a directory.
  @unopenable "/m/j/x"

  defp bash(files \\ %{}) do
    JustBash.new(files: Map.merge(%{"/m/j" => "parent\n"}, files))
  end

  defp exists?(bash, path), do: bash.fs |> FS.exists?(path) |> elem(0)

  defp read(bash, path) do
    case FS.read_file(bash.fs, path) do
      {:ok, content, _fs} -> content
      {:error, %VFS.Error{kind: kind}} -> {:error, kind}
    end
  end

  describe "a failed open stops the command body from running" do
    test "mkdir does not create its directory" do
      {result, b} = JustBash.exec(bash(), "mkdir /made > #{@unopenable}")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: #{@unopenable}: Not a directory\n"
      refute exists?(b, "/made")
    end

    test "touch does not create its file" do
      {result, b} = JustBash.exec(bash(), "touch /t.txt > #{@unopenable}")

      assert result.exit_code == 1
      refute exists?(b, "/t.txt")
    end

    test "the repro from the issue reports absent, not MADE" do
      {result, b} =
        JustBash.exec(
          bash(%{"/m/j" => "f\n"}),
          "mkdir /made > /m/j/x; [ -d /made ] && echo MADE || echo absent"
        )

      assert result.stdout == "absent\n"
      refute exists?(b, "/made")
    end

    test "a failed >> open also stops the body" do
      {result, b} = JustBash.exec(bash(), "mkdir /made >> #{@unopenable}")

      assert result.exit_code == 1
      assert result.stderr == "bash: #{@unopenable}: Not a directory\n"
      refute exists?(b, "/made")
    end

    test "a failed 2> open stops the body, even though only stderr was redirected" do
      {result, b} = JustBash.exec(bash(), "mkdir /made 2> #{@unopenable}")

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "bash: #{@unopenable}: Not a directory\n"
      refute exists?(b, "/made")
    end

    test "a failed &> open stops the body" do
      {result, b} = JustBash.exec(bash(), "mkdir /made &> #{@unopenable}")

      assert result.exit_code == 1
      refute exists?(b, "/made")
    end

    test "a directory target stops the body too" do
      {result, b} = JustBash.exec(bash(), "mkdir -p /d && mkdir /made > /d")

      assert result.exit_code == 1
      assert result.stderr == "bash: /d: Is a directory\n"
      refute exists?(b, "/made")
    end

    test "a shell function body does not run either" do
      script = """
      f() { mkdir /made; }
      f > #{@unopenable}
      """

      {result, b} = JustBash.exec(bash(), script)

      assert result.exit_code == 1
      refute exists?(b, "/made")
    end

    test "a builtin that mutates shell state does not run" do
      {result, b} = JustBash.exec(bash(), "mkdir -p /elsewhere; cd /elsewhere > #{@unopenable}")

      assert result.exit_code == 1
      assert b.cwd != "/elsewhere"
    end
  end

  describe "a failed open stops each compound command's body" do
    test "for" do
      {result, b} = JustBash.exec(bash(), "for i in 1 2 3; do mkdir /L$i; done > #{@unopenable}")

      assert result.exit_code == 1
      assert result.stderr == "bash: #{@unopenable}: Not a directory\n"
      refute exists?(b, "/L1")
      refute exists?(b, "/L2")
      refute exists?(b, "/L3")
    end

    test "while" do
      script = "i=0; while [ $i -lt 2 ]; do mkdir /W$i; i=$((i+1)); done > #{@unopenable}"
      {result, b} = JustBash.exec(bash(), script)

      assert result.exit_code == 1
      refute exists?(b, "/W0")
      refute exists?(b, "/W1")
    end

    test "until" do
      script = "i=0; until [ $i -ge 2 ]; do mkdir /U$i; i=$((i+1)); done > #{@unopenable}"
      {result, b} = JustBash.exec(bash(), script)

      assert result.exit_code == 1
      refute exists?(b, "/U0")
      refute exists?(b, "/U1")
    end

    test "subshell" do
      {result, b} = JustBash.exec(bash(), "( mkdir /S1; echo in ) > #{@unopenable}")

      assert result.exit_code == 1
      assert result.stdout == ""
      refute exists?(b, "/S1")
    end

    test "group" do
      {result, b} = JustBash.exec(bash(), "{ mkdir /G1; echo in ; } > #{@unopenable}")

      assert result.exit_code == 1
      assert result.stdout == ""
      refute exists?(b, "/G1")
    end
  end

  describe "opening the target creates or truncates it" do
    test "> truncates before the body runs, so a command cannot read its own target" do
      {result, b} = JustBash.exec(bash(), "printf 'a\\nb\\n' > /data; cat /data > /data")

      assert result.exit_code == 0
      assert read(b, "/data") == ""
    end

    test ">> does not truncate, so the body appends to what was there" do
      {_result, b} = JustBash.exec(bash(), "echo one > /app.txt; echo two >> /app.txt")

      assert read(b, "/app.txt") == "one\ntwo\n"
    end

    test ">> leaves an existing target's mtime alone" do
      b = JustBash.new(files: %{"/keep.txt" => "one\n"})
      {:ok, %VFS.Stat{mtime: before}, _fs} = FS.stat(b.fs, "/keep.txt")

      {_result, b} = JustBash.exec(b, "true >> /keep.txt")

      assert {:ok, %VFS.Stat{mtime: ^before}, _fs} = FS.stat(b.fs, "/keep.txt")
      assert read(b, "/keep.txt") == "one\n"
    end

    test "a loop's target is opened once for the whole loop, not per iteration" do
      script = "printf 'X\\n' > /lo; for i in 1 2 3; do echo $i; done > /lo"
      {_result, b} = JustBash.exec(bash(), script)

      assert read(b, "/lo") == "1\n2\n3\n"
    end

    test "a target left of a failing one is still truncated" do
      script = "echo pre > /ok.txt; echo hi > /ok.txt > #{@unopenable}"
      {result, b} = JustBash.exec(bash(), script)

      assert result.exit_code == 1
      assert read(b, "/ok.txt") == ""
    end

    test "a target right of a failing one is never opened" do
      {result, b} = JustBash.exec(bash(), "echo hi > #{@unopenable} > /right.txt")

      assert result.exit_code == 1
      refute exists?(b, "/right.txt")
    end
  end

  describe "the target is expanded exactly once" do
    defmodule NextName do
      @moduledoc """
      Returns a different path on each call, so the target a redirection
      actually writes to reveals how many times it was expanded.
      """
      @behaviour JustBash.Commands.Command

      @impl true
      def names, do: ["next-name"]

      @impl true
      def execute(bash, _args, _stdin) do
        n = Agent.get_and_update(__MODULE__, &{&1, &1 + 1})
        {%{stdout: "/call#{n}.txt\n", stderr: "", exit_code: 0}, bash}
      end
    end

    setup do
      start_supervised!(%{
        id: NextName,
        start: {Agent, :start_link, [fn -> 0 end, [name: NextName]]}
      })

      :ok
    end

    test "a command substitution in the target runs once, before the body" do
      b = JustBash.new(commands: %{"next-name" => NextName})
      {result, b} = JustBash.exec(b, "echo hi > $(next-name)")

      assert result.exit_code == 0
      assert read(b, "/call0.txt") == "hi\n"
      refute exists?(b, "/call1.txt")
    end

    test "a command substitution right of a failing target does not run at all" do
      b = JustBash.new(files: %{"/m/j" => "parent\n"}, commands: %{"next-name" => NextName})
      {result, b} = JustBash.exec(b, "echo hi > #{@unopenable} > $(next-name)")

      assert result.exit_code == 1
      refute exists?(b, "/call0.txt")
      assert Agent.get(NextName, & &1) == 0
    end

    test "a compound command's target is expanded once, not once per iteration" do
      b = JustBash.new(commands: %{"next-name" => NextName})
      {result, b} = JustBash.exec(b, "for i in 1 2 3; do echo $i; done > $(next-name)")

      assert result.exit_code == 0
      assert read(b, "/call0.txt") == "1\n2\n3\n"
      refute exists?(b, "/call1.txt")
    end
  end

  describe "successful redirections still behave as they did" do
    test "the redirected stdout lands in the file and not in the result" do
      {result, b} = JustBash.exec(bash(), "echo hi > /out.txt")

      assert result.exit_code == 0
      assert result.stdout == ""
      assert read(b, "/out.txt") == "hi\n"
    end

    test "a failing command still truncates its target" do
      {result, b} = JustBash.exec(bash(), "echo old > /f.txt; false > /f.txt")

      assert result.exit_code == 1
      assert read(b, "/f.txt") == ""
    end

    test "&& short-circuits on a failed open" do
      {result, _b} =
        JustBash.exec(bash(), "echo hi > #{@unopenable} && echo AND || echo OR")

      assert result.stdout == "OR\n"
    end

    test "> /dev/null still discards stdout" do
      {result, b} = JustBash.exec(bash(), "echo hi > /dev/null")

      assert result.exit_code == 0
      assert result.stdout == ""
      assert exists?(b, "/dev/null")
    end

    test "2>&1 still folds stderr into stdout" do
      {result, _b} = JustBash.exec(bash(), "ls /nope 2>&1")

      assert result.stderr == ""
      assert result.stdout =~ "/nope"
    end

    test "a heredoc still reaches the body as stdin" do
      {result, _b} = JustBash.exec(bash(), "cat <<EOF\nline\nEOF\n")

      assert result.stdout == "line\n"
    end

    test "< reads the file without the target being opened for writing" do
      {result, b} = JustBash.exec(bash(%{"/in.txt" => "data\n"}), "cat < /in.txt")

      assert result.stdout == "data\n"
      assert read(b, "/in.txt") == "data\n"
    end
  end
end
