defmodule JustBash.SandboxContractTest do
  @moduledoc """
  The two guarantees `JustBash.exec/2` owes a host that runs untrusted script
  text: it returns, and it returns a shell-shaped result rather than raising.

  See issue #69.
  """

  use ExUnit.Case, async: true

  alias JustBash.Limit

  # --- Probes ---

  defmodule Boom do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["boom"]

    @impl true
    def execute(_bash, _args, _stdin), do: raise(ArgumentError, "from inside a command")
  end

  # Hands back a structurally valid result alongside a wrecked `JustBash` struct,
  # so the *next* command — a registry builtin — is the one that raises.
  defmodule Wreck do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["wreck"]

    @impl true
    def execute(bash, _args, _stdin) do
      {%{stdout: "", stderr: "", exit_code: 0}, %{bash | fs: :not_a_filesystem}}
    end
  end

  # Same idea, but the wreckage is in `env`, so the raise happens during
  # expansion — outside command dispatch entirely.
  defmodule WreckEnv do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["wreck-env"]

    @impl true
    def execute(bash, _args, _stdin) do
      {%{stdout: "", stderr: "", exit_code: 0}, %{bash | env: :not_a_map}}
    end
  end

  defmodule Spin do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["spin"]

    @impl true
    def execute(bash, _args, _stdin) do
      Process.sleep(10)
      {%{stdout: "", stderr: "", exit_code: 0}, bash}
    end
  end

  defp probe_bash(opts \\ []) do
    JustBash.new(
      [commands: %{"boom" => Boom, "wreck" => Wreck, "wreck-env" => WreckEnv, "spin" => Spin}] ++
        opts
    )
  end

  describe "exec/2 contains an unexpected raise" do
    test "a custom command that raises becomes a non-zero exit" do
      {result, _bash} = JustBash.exec(probe_bash(), "boom")

      assert result.exit_code == 1
      assert result.stderr =~ "bash: boom: custom command crashed (ArgumentError:"
    end

    test "a registry builtin that raises becomes a non-zero exit" do
      {result, _bash} = JustBash.exec(probe_bash(), "wreck; cat /etc/hosts")

      assert result.exit_code == 1
      assert result.stderr =~ "bash: cat: command crashed (FunctionClauseError:"
      assert result.stdout == ""
    end

    test "a raise from outside command dispatch becomes a non-zero exit" do
      {result, _bash} = JustBash.exec(probe_bash(), "wreck-env; echo $HOME")

      assert result.exit_code == 1
      assert result.stderr =~ "bash: internal error ("
    end

    test "an argument a builtin cannot parse does not escape as an Elixir exception" do
      # `head -n abc` raised FunctionClauseError out of exec/2. The diagnostic
      # text is the arg-parsing layer's business; the contract here is only that
      # the host gets a shell result back.
      {result, _bash} = JustBash.exec(JustBash.new(), "head -n abc")

      assert result.exit_code != 0
      assert result.stderr != ""
    end

    test "a contained crash does not halt the rest of the script" do
      {result, _bash} = JustBash.exec(probe_bash(), "boom; echo after")

      assert result.stdout == "after\n"
      assert result.stderr =~ "custom command crashed"
    end

    test "limit breaches keep their own diagnostic rather than reading as a crash" do
      bash = JustBash.new(limits: [max_steps: 5])
      {result, _bash} = JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i; done")

      assert result.exit_code == 1
      assert result.stderr =~ "execution step limit exceeded"
      refute result.stderr =~ "crashed"
    end
  end

  describe "exec!/2" do
    test "arms the wall clock like exec/2" do
      # Unlike `max_steps`, the wall clock has to be armed, so an entry point
      # that skips arming silently has no bound at all.
      bash = probe_bash(limits: [max_wall_ms: 30, max_steps: 10_000_000])

      {elapsed_us, {result, final}} =
        :timer.tc(fn -> JustBash.exec!(bash, "for i in $(seq 1 100); do spin; done") end)

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (30 ms)"
      assert final.interpreter.deadline != nil
      assert elapsed_us < 300_000
    end

    test "propagates an interpreter exception rather than containing it" do
      # The documented difference from `exec/2`: `exec!/2` is the uncontained
      # entry point. A host running untrusted script text wants `exec/2`.
      assert catch_error(JustBash.exec!(probe_bash(), "wreck-env; echo $HOME"))

      {result, _bash} = JustBash.exec(probe_bash(), "wreck-env; echo $HOME")
      assert result.exit_code == 1
    end

    test "raises on a parse error" do
      assert_raise RuntimeError, ~r/Parse error/, fn ->
        JustBash.exec!(JustBash.new(), "echo 'unterminated")
      end
    end
  end

  describe "a crashed command reports through composition" do
    # Oracle: GNU bash 3.2/5.x. `cmd | cat`, `echo $(cmd)` and `if cmd; then fi`
    # are all exit 0 — the pipeline reports its last stage, and `if` with no
    # matching branch is success. What must survive is the diagnostic.
    test "stderr from a non-final pipeline stage reaches the caller" do
      {result, _bash} = JustBash.exec(JustBash.new(), "cat /nope | cat")

      assert result.exit_code == 0
      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "a crash in a non-final pipeline stage reaches the caller" do
      {result, _bash} = JustBash.exec(probe_bash(), "boom | cat")

      assert result.exit_code == 0
      assert result.stderr =~ "custom command crashed"
    end

    test "every failing stage of a pipeline reports" do
      {result, _bash} = JustBash.exec(JustBash.new(), "cat /nope | cat /nada | cat")

      assert result.stderr ==
               "cat: /nope: No such file or directory\ncat: /nada: No such file or directory\n"
    end

    test "a redirected stage stays silent" do
      {result, _bash} = JustBash.exec(JustBash.new(), "cat /nope 2>/dev/null | cat")

      assert result.stderr == ""
    end

    test "PIPESTATUS still records the failing stage" do
      {result, _bash} = JustBash.exec(JustBash.new(), "cat /nope | cat; echo ${PIPESTATUS[0]}")

      assert result.stdout == "1\n"
    end

    test "pipefail still surfaces the failing stage's exit code" do
      {result, _bash} = JustBash.exec(probe_bash(), "set -o pipefail; boom | cat")

      assert result.exit_code == 1
    end

    test "a crash inside an if condition takes the else branch" do
      {result, _bash} = JustBash.exec(probe_bash(), "if boom; then echo yes; else echo no; fi")

      assert result.exit_code == 0
      assert result.stdout == "no\n"
    end
  end

  describe "command substitution" do
    # Oracle: GNU bash 3.2.57. A substitution's diagnostic always reaches the
    # shell's stderr — even past a `2>` on the enclosing command, since the
    # expansion happens before the redirection is performed. Its exit status is
    # reported as `$?` only when nothing else in the statement claims `$?`:
    # a bare assignment takes the *last* substitution's status, while a command
    # (including the `export`/`local` builtins) reports its own.
    test "a diagnostic from inside a substitution reaches the caller" do
      {result, _bash} = JustBash.exec(JustBash.new(), "echo $(cat /nope)")

      assert result.stdout == "\n"
      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "a diagnostic survives a redirection on the enclosing command" do
      {result, _bash} = JustBash.exec(JustBash.new(), "echo $(cat /nope) 2>/dev/null")

      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "a diagnostic from a quoted substitution reaches the caller" do
      {result, _bash} = JustBash.exec(JustBash.new(), "echo \"$(cat /nope)\"")

      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "a diagnostic from a substitution nested in a parameter expansion reaches the caller" do
      {result, _bash} = JustBash.exec(JustBash.new(), "echo ${x:-$(cat /nope)}")

      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "every substitution in a command reports" do
      {result, _bash} = JustBash.exec(JustBash.new(), "echo $(cat /nope) $(cat /nada)")

      assert result.stderr ==
               "cat: /nope: No such file or directory\ncat: /nada: No such file or directory\n"
    end

    test "a bare assignment reports the substitution's exit code as $?" do
      {result, _bash} = JustBash.exec(JustBash.new(), "x=$(cat /nope); echo code=$? x=$x")

      assert result.stdout == "code=1 x=\n"
      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "a bare assignment whose substitution succeeds stays at zero" do
      {result, _bash} = JustBash.exec(JustBash.new(), "x=$(echo hi); echo code=$? x=$x")

      assert result.stdout == "code=0 x=hi\n"
      assert result.stderr == ""
    end

    test "a bare assignment with no substitution stays at zero" do
      {result, _bash} = JustBash.exec(JustBash.new(), "x=1; echo code=$? x=$x")

      assert result.stdout == "code=0 x=1\n"
    end

    test "a bare assignment reports the last substitution of several" do
      {result, _bash} =
        JustBash.exec(JustBash.new(), "y=$(cat /nope) x=$(cat /nada); echo code=$?")

      assert result.stdout == "code=1\n"

      assert result.stderr ==
               "cat: /nope: No such file or directory\ncat: /nada: No such file or directory\n"
    end

    test "a failing substitution is the script's exit code when it is the last statement" do
      {result, _bash} = JustBash.exec(JustBash.new(), "x=$(cat /nope)")

      assert result.exit_code == 1
      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "a crashed command inside a substitution is not a silent success" do
      {result, _bash} = JustBash.exec(probe_bash(), "x=$(boom)")

      assert result.exit_code == 1
      assert result.stderr =~ "custom command crashed"
    end

    test "export keeps its own exit code, per POSIX" do
      {result, _bash} = JustBash.exec(JustBash.new(), "export x=$(cat /nope); echo code=$?")

      assert result.stdout == "code=0\n"
      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "local keeps its own exit code, per POSIX" do
      script = "f() { local y=$(cat /nope); echo code=$?; }; f"
      {result, _bash} = JustBash.exec(JustBash.new(), script)

      assert result.stdout == "code=0\n"
      assert result.stderr == "cat: /nope: No such file or directory\n"
    end

    test "a command reports its own exit code, not the substitution's" do
      {result, _bash} = JustBash.exec(JustBash.new(), "echo $(cat /nope); echo code=$?")

      assert result.stdout == "\ncode=0\n"
    end

    test "an assignment prefixing a command reports both diagnostics" do
      {result, _bash} = JustBash.exec(JustBash.new(), "x=$(cat /nope) cat /nada; echo code=$?")

      assert result.stdout == "code=1\n"

      assert result.stderr ==
               "cat: /nope: No such file or directory\ncat: /nada: No such file or directory\n"
    end
  end

  describe "max_wall_ms" do
    test "is part of the default limits" do
      assert Limit.defaults().max_wall_ms == 5_000
      assert Limit.new(:strict).max_wall_ms == 1_000
      assert Limit.new(:relaxed).max_wall_ms == 30_000
      assert Limit.new(max_wall_ms: 42).max_wall_ms == 42
    end

    test "bounds a script that spins without approaching any other limit" do
      bash = probe_bash(limits: [max_wall_ms: 30, max_steps: 10_000_000])

      {elapsed_us, {result, final}} =
        :timer.tc(fn -> JustBash.exec(bash, "for i in $(seq 1 200); do spin; done") end)

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (30 ms)"
      assert final.interpreter.step_count < 10_000_000
      assert elapsed_us < 2_000_000
    end

    test "a script that finishes inside the budget is untouched" do
      bash = JustBash.new(limits: [max_wall_ms: 5_000])
      {result, _bash} = JustBash.exec(bash, "for i in 1 2 3; do echo $i; done")

      assert result.exit_code == 0
      assert result.stdout == "1\n2\n3\n"
    end

    test "the deadline is rearmed for each top-level exec" do
      bash = probe_bash(limits: [max_wall_ms: 200])

      {result, bash} = JustBash.exec(bash, "spin; spin; echo one")
      assert result.stdout == "one\n"

      {result, _bash} = JustBash.exec(bash, "spin; spin; echo two")
      assert result.stdout == "two\n"
    end

    test "limits: false disables the wall clock too" do
      bash = probe_bash(limits: false)
      {result, _bash} = JustBash.exec(bash, "spin; echo ok")

      assert result.exit_code == 0
      assert result.stdout == "ok\n"
    end

    test "rejects a non-positive value like every other bound" do
      assert_raise ArgumentError, ~r/positive integers/, fn ->
        Limit.new(max_wall_ms: 0)
      end
    end
  end

  describe "a loop inside a single command" do
    # The statement loop is never re-entered while one command spins, and a
    # whole command is one step, so only a deadline checked *inside* the
    # command's own loop bounds it. This is the shape of the `printf '%b'`
    # hang (56c74b8) issue #69 cites. Each probe runs under a task so a
    # regression fails the test instead of hanging the suite.
    setup do
      {:ok, bash: JustBash.new(limits: [max_wall_ms: 50, max_steps: 10_000_000])}
    end

    defp bounded_exec(bash, script) do
      task = Task.async(fn -> JustBash.exec(bash, script) end)

      case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {result, _bash}} -> result
        nil -> flunk("`#{script}` did not terminate within 5s")
      end
    end

    test "awk's while loop is bounded", %{bash: bash} do
      result = bounded_exec(bash, "awk 'BEGIN{while(1){x=x+1}}'")

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (50 ms)"
    end

    test "awk's for loop is bounded", %{bash: bash} do
      result = bounded_exec(bash, "awk 'BEGIN{for(i=0;i>=0;i++){}}'")

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (50 ms)"
    end

    test "awk's do-while loop is bounded", %{bash: bash} do
      result = bounded_exec(bash, "awk 'BEGIN{do{x=x+1}while(1)}'")

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (50 ms)"
    end

    test "seq's range walk is bounded", %{bash: bash} do
      result = bounded_exec(bash, "seq 1 100000000")

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (50 ms)"
    end

    test "an awk loop that terminates on its own is untouched", %{bash: bash} do
      result = bounded_exec(bash, "awk 'BEGIN{for(i=0;i<3;i++){print i}}'")

      assert result.exit_code == 0
      assert result.stdout == "0\n1\n2\n"
    end
  end

  describe "a recursive traversal" do
    # `find` never returned through a symlink cycle (#53). The cycle is gone,
    # but nothing structural stopped the next one — a whole tree walk is one
    # step, so only the wall clock can bound it, and every recursive command
    # hand-rolls its own descent. Unbounded, these run 300-700 ms on this tree.
    setup do
      files = for i <- 1..2000, into: %{}, do: {"/tree/#{rem(i, 20)}/#{i}/f.txt", "hello #{i}"}

      {:ok,
       files: files,
       bash: JustBash.new(files: files, limits: [max_wall_ms: 50, max_steps: 10_000_000])}
    end

    for {command, script} <- [
          {"find", "find /tree"},
          {"grep -r", "grep -r hello /tree"},
          {"du", "du /tree"},
          {"tree", "tree /tree"},
          {"cp -r", "cp -r /tree /copy"}
        ] do
      test "#{command} is bounded by the wall clock", %{bash: bash} do
        {elapsed_us, {result, _bash}} =
          :timer.tc(fn -> JustBash.exec(bash, unquote(script) <> " > /dev/null") end)

        assert result.exit_code == 1
        assert result.stderr =~ "execution wall clock limit exceeded (50 ms)"
        assert elapsed_us < 300_000
      end
    end

    test "a traversal that fits inside the budget is untouched", %{files: files} do
      bash = JustBash.new(files: files, limits: [max_wall_ms: 30_000])
      {result, _bash} = JustBash.exec(bash, "find /tree -name f.txt | wc -l")

      assert result.exit_code == 0
      assert result.stdout == "2000\n"
    end
  end

  describe "Limit.check_deadline!/1" do
    test "passes when there is no deadline" do
      assert Limit.check_deadline!(nil) == :ok
    end

    test "passes before the deadline and raises after it" do
      deadline = Limit.deadline(Limit.new(max_wall_ms: 10_000))
      assert Limit.check_deadline!(deadline) == :ok

      expired = Limit.deadline(Limit.new(max_wall_ms: 1))
      Process.sleep(5)

      assert_raise Limit.ExceededError, ~r/wall clock limit exceeded \(1 ms\)/, fn ->
        Limit.check_deadline!(expired)
      end
    end
  end

  describe "Limit.enforce_deadline/2" do
    test "passes the enumerable through untouched without a deadline" do
      assert 1..20 |> Limit.enforce_deadline(nil) |> Enum.count() == 20
    end

    test "yields every element while the deadline holds" do
      deadline = Limit.deadline(Limit.new(max_wall_ms: 10_000))
      assert 1..20 |> Limit.enforce_deadline(deadline) |> Enum.count() == 20
    end

    test "raises once the deadline has passed" do
      expired = Limit.deadline(Limit.new(max_wall_ms: 1))
      Process.sleep(5)

      assert_raise Limit.ExceededError, ~r/wall clock limit exceeded/, fn ->
        1..20 |> Limit.enforce_deadline(expired) |> Enum.to_list()
      end
    end
  end
end
