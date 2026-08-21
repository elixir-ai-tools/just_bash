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

  # A telemetry handler is global, so other async modules hit it too; only the
  # commands this module drives are forwarded to the waiting test.
  def forward_exception(event, measurements, %{command: command} = metadata, test_pid)
      when command in ["cat", "boom", "echo"] do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  def forward_exception(_event, _measurements, _metadata, _test_pid), do: :ok

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

  describe "an internal error" do
    test "keeps the output and the session state of the statements before it" do
      # Containment must not mean amnesia. The neighbouring Limit.ExceededError
      # handler already behaves this way; this one must match it.
      script = "echo hi > /f.txt; export FOO=bar; echo before; wreck-env; echo $HOME"
      {result, bash} = JustBash.exec(probe_bash(), script)

      assert result.exit_code == 1
      assert result.stdout == "before\n"
      assert result.stderr =~ "bash: internal error ("

      {result, _bash} = JustBash.exec(bash, "cat /f.txt; echo FOO=$FOO")
      assert result.stdout == "hi\nFOO=bar\n"
    end

    test "halts the rest of the script, the way a limit breach does" do
      {result, _bash} = JustBash.exec(probe_bash(), "echo before; wreck-env; echo after")

      assert result.exit_code == 1
      assert result.stdout == "before\n"
      refute result.stdout =~ "after"
    end

    test "a limit breach keeps the output of the statements before it" do
      # The behaviour the internal-error path is being held to.
      bash = JustBash.new(limits: [max_steps: 4])
      script = "echo a > /f.txt; echo one; echo two; echo three; echo four; echo five"
      {result, bash} = JustBash.exec(bash, script)

      assert result.exit_code == 1
      assert result.stdout == "one\ntwo\nthree\n"

      {result, _bash} = JustBash.exec(bash, "cat /f.txt")
      assert result.stdout == "a\n"
    end

    test "has a stderr that respects max_output_bytes" do
      # `Exception.message/1` is unbounded from the sandbox's point of view —
      # `inspect/1` alone allows 4096 bytes per binary — so a MatchError or
      # KeyError carrying interpreter or filesystem state could inline sandbox
      # file contents into a stderr the host asked to be capped.
      bash = probe_bash(limits: [max_output_bytes: 100])
      {result, _bash} = JustBash.exec(bash, "wreck-env; echo $HOME")

      assert result.exit_code == 1
      assert result.stderr =~ "bash: internal error ("
      assert byte_size(result.stderr) <= 100
    end

    test "has a stderr that stays bounded under generous limits" do
      {result, _bash} = JustBash.exec(probe_bash(limits: :relaxed), "wreck-env; echo $HOME")

      assert result.exit_code == 1
      assert byte_size(result.stderr) <= 512
    end
  end

  describe "telemetry" do
    # Containing a crash must not retire the documented
    # [:just_bash, :command, :exception] event: the failure class this PR
    # contains used to be loud, and a host can already subscribe to it.
    setup do
      handler = "sandbox-contract-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:just_bash, :command, :exception],
        &__MODULE__.forward_exception/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "a contained registry crash still emits [:just_bash, :command, :exception]" do
      {result, _bash} = JustBash.exec(probe_bash(), "wreck; cat /etc/hosts")

      assert result.exit_code == 1
      assert_receive {:telemetry, [:just_bash, :command, :exception], measurements, metadata}
      assert metadata.command == "cat"
      assert metadata.kind == :error
      assert metadata.reason == :function_clause
      assert is_list(metadata.stacktrace)
      assert is_integer(measurements.duration)
    end

    test "a contained custom-command crash still emits [:just_bash, :command, :exception]" do
      {result, _bash} = JustBash.exec(probe_bash(), "boom")

      assert result.exit_code == 1
      assert_receive {:telemetry, [:just_bash, :command, :exception], _measurements, metadata}
      assert metadata.command == "boom"
    end

    test "a command that does not raise emits no exception event" do
      {result, _bash} = JustBash.exec(JustBash.new(), "echo ok")

      assert result.exit_code == 0
      refute_receive {:telemetry, [:just_bash, :command, :exception], _, _}, 50
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

    test "contains an internal error, because the statement loop does" do
      # The containment lives in the interpreter now, not in `exec/2`'s rescue,
      # so both public entry points get it.
      {result, _bash} = JustBash.exec!(probe_bash(), "wreck-env; echo $HOME")

      assert result.exit_code == 1
      assert result.stderr =~ "bash: internal error ("
    end

    test "raises on a parse error, where exec/2 returns a syntax-error result" do
      assert_raise RuntimeError, ~r/Parse error/, fn ->
        JustBash.exec!(JustBash.new(), "echo 'unterminated")
      end

      {result, _bash} = JustBash.exec(JustBash.new(), "echo 'unterminated")
      assert result.exit_code == 2
      assert result.stderr =~ "bash: syntax error:"
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
      # On the order of the bound it guards, not 66x it: a deadline that fired
      # sixty times late must not pass.
      assert elapsed_us < 300_000
    end

    test "a script that finishes inside the budget is untouched" do
      bash = JustBash.new(limits: [max_wall_ms: 5_000])
      {result, _bash} = JustBash.exec(bash, "for i in 1 2 3; do echo $i; done")

      assert result.exit_code == 0
      assert result.stdout == "1\n2\n3\n"
    end

    test "the deadline is rearmed for each top-level exec" do
      # Six execs of ~55 ms against a 200 ms budget. Each one on its own is
      # comfortably inside the budget, so the run only stays green if every
      # exec starts a fresh one — arming once and never refreshing runs out
      # partway through.
      bash = probe_bash(limits: [max_wall_ms: 200, max_steps: 10_000_000])

      Enum.reduce(1..6, bash, fn i, bash ->
        {result, bash} = JustBash.exec(bash, "spin; spin; spin; spin; spin; echo #{i}")

        assert result.exit_code == 0, "exec #{i}: #{result.stderr}"
        assert result.stdout == "#{i}\n"
        bash
      end)
    end

    test "each exec's deadline is a later instant than the previous one's" do
      # The structural half of the same guarantee, immune to how fast the
      # machine is: rearming must move `at_ms` forward.
      bash = probe_bash(limits: [max_wall_ms: 5_000])

      {_result, first} = JustBash.exec(bash, "echo one")
      Process.sleep(5)
      {_result, second} = JustBash.exec(first, "echo two")

      assert second.interpreter.deadline.at_ms > first.interpreter.deadline.at_ms
    end

    test "limits: false disables the wall clock too" do
      bash = probe_bash(limits: false)
      {result, bash} = JustBash.exec(bash, "spin; echo ok")

      assert result.exit_code == 0
      assert result.stdout == "ok\n"
      # Structural, because 10 ms of work passes under any non-degenerate
      # budget: `Limit.deadline(nil)` must not quietly hand back a
      # default-budget deadline.
      assert bash.limits == nil
      assert bash.interpreter.deadline == nil
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
      {_elapsed_us, result} = bounded_exec_timed(bash, script)
      result
    end

    # The clock is read *inside* the task, so a probe that asserts on elapsed
    # time measures the run itself rather than the yield, and still fails at 5s
    # instead of wedging the suite.
    defp bounded_exec_timed(bash, script) do
      task = Task.async(fn -> :timer.tc(fn -> JustBash.exec(bash, script) end) end)

      case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {elapsed_us, {result, _bash}}} -> {elapsed_us, result}
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

    test "awk's empty for(;;) is a loop, not a no-op, and is still bounded", %{bash: bash} do
      result = bounded_exec(bash, "awk 'BEGIN{for(;;){x=x+1}}'")

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

    test "an awk loop that terminates on its own is untouched" do
      # A budget the shared 50 ms one cannot flake against under a loaded suite.
      bash = JustBash.new(limits: [max_wall_ms: 30_000])
      result = bounded_exec(bash, "awk 'BEGIN{for(i=0;i<3;i++){print i}}'")

      assert result.exit_code == 0
      assert result.stdout == "0\n1\n2\n"
    end
  end

  describe "an expansion that generates from a short input" do
    # A word is one step, so the step counter never sees inside an expansion —
    # and brace expansion is the one path where a handful of characters names
    # an arbitrarily large word list. Measured on the pre-fix tree under
    # `:strict`: `echo {1..100000}` took 18.3 s and `echo {1..1000000}` never
    # returned. Each probe runs under a task so a regression fails the test
    # instead of wedging the suite.
    setup do
      {:ok, bash: JustBash.new(limits: [max_wall_ms: 50, max_steps: 5_000])}
    end

    for {label, script} <- [
          {"a flat range", "echo {1..1000000}"},
          {"a nested product", "echo {1..300}{1..300}{1..300}"},
          {"a list crossed with a range", "echo {a,b,c}{1..500000}"},
          {"a `for` list", "for i in {1..1000000}; do :; done"},
          {"an array assignment", "a=({1..1000000}); echo ${#a[@]}"}
        ] do
      test "#{label} is bounded", %{bash: bash} do
        result = bounded_exec(bash, unquote(script))

        # Unbounded, each of these is exit 0 with empty stderr — when it
        # returns at all.
        assert result.exit_code == 1
        assert result.stderr =~ "limit exceeded"
      end
    end

    test "a range is refused before it is built, not after" do
      # A range materializes in one go, so counting words as they arrive is too
      # late — the memory is already spent. `elapsed_us` is what distinguishes
      # the two: measured, this range costs 880 ms and ~1 GB to build and 0 ms
      # to measure. The clock gets room it cannot need so cardinality answers.
      bash = JustBash.new(limits: [max_steps: 100, max_wall_ms: 30_000])

      {elapsed_us, result} = bounded_exec_timed(bash, "echo {1..20000000}")

      assert result.exit_code == 1
      assert result.stderr =~ "word expansion limit exceeded (100 words)"
      assert elapsed_us < 200_000
    end

    test "a product of ranges each inside the bound is still counted" do
      # Neither range is refusable on its own — 50 is well under the cap — so
      # the 2,500 words their product names are caught only by counting as the
      # walk produces them. The clock again has room it cannot need.
      bash = JustBash.new(limits: [max_steps: 100, max_wall_ms: 30_000])
      result = bounded_exec(bash, "echo {1..50}{1..50}")

      assert result.exit_code == 1
      assert result.stderr =~ "word expansion limit exceeded (100 words)"
    end

    test "the wall clock still bounds a word list the cardinality cap allows" do
      # A million words is inside a ten-million step budget, so cardinality has
      # nothing to say; only the deadline checked inside the walk stops this.
      bash = JustBash.new(limits: [max_steps: 10_000_000, max_wall_ms: 50])
      result = bounded_exec(bash, "echo {1..1000}{1..1000}")

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (50 ms)"
    end

    test "an expansion that fits inside the budget is untouched" do
      bash = JustBash.new(limits: [max_steps: 100, max_wall_ms: 30_000])
      result = bounded_exec(bash, "echo {1..5} {a..e} {x,y}{1..3}")

      assert result.exit_code == 0
      assert result.stdout == "1 2 3 4 5 a b c d e x1 x2 x3 y1 y2 y3\n"
    end

    test "a word list right at the bound is allowed" do
      bash = JustBash.new(limits: [max_steps: 100, max_wall_ms: 30_000])
      result = bounded_exec(bash, "echo {1..10}{1..10} | wc -w")

      assert result.exit_code == 0
      assert result.stdout == "100\n"
    end
  end

  describe "a value that grows from a short input" do
    # Deadline checks sit between statements. One `v=${v}${v}` doubles a binary
    # with no size cap, so the next check cannot fire until that allocation
    # finishes — measured at ~2.4–2.9× `max_wall_ms` on a 1s budget, and the
    # overrun grows with the value. `max_value_bytes` refuses before the
    # concat, the way `check_expansion_words!/2` refuses before a range is
    # built. Each probe runs under a task so a regression fails the test
    # instead of OOMing the suite.
    setup do
      {:ok,
       bash: JustBash.new(limits: [max_value_bytes: 1_000, max_wall_ms: 5_000, max_steps: 10_000])}
    end

    test "string doubling is refused before a huge allocation", %{bash: bash} do
      {elapsed_us, result} =
        bounded_exec_timed(bash, "v=abc; while true; do v=${v}${v}; done")

      assert result.exit_code == 1
      assert result.stderr =~ "value size limit exceeded (1000 bytes)"
      # Unbounded, this is the GB-scale concat that overran `max_wall_ms` by
      # ~3×. Under a 1_000-byte cap it must finish on the order of a few
      # doublings, not a wall-clock budget.
      assert elapsed_us < 200_000
    end

    test "unquoted doubling is the same hole", %{bash: bash} do
      result = bounded_exec(bash, "v=abc; while true; do v=$v$v; done")

      assert result.exit_code == 1
      assert result.stderr =~ "value size limit exceeded (1000 bytes)"
    end

    test "a normal-size assignment is untouched" do
      bash = JustBash.new(limits: [max_value_bytes: 1_000])
      result = bounded_exec(bash, "v=hello; v=${v}${v}; echo $v")

      assert result.exit_code == 0
      assert result.stdout == "hellohello\n"
    end

    test "limits: false leaves doubling unbounded by value size" do
      bash = JustBash.new(limits: false)
      result = bounded_exec(bash, "v=ab; v=${v}${v}; v=${v}${v}; echo ${#v}")

      assert result.exit_code == 0
      assert result.stdout == "8\n"
    end

    test "global pattern replacement is refused before a huge allocation" do
      # #85 bounded `v=${v}${v}`. `${v//a/$r}` still allocates first:
      # `Regex.replace/4` runs, then `concat!` sees the finished binary.
      # 15 doublings sit `v` and `r` at the 32_768-byte cap; unbounded, the
      # replace is |v| * |r| = 1 GiB and (measured) ~700 ms. concat! cannot
      # refuse until that allocation finishes.
      bash =
        JustBash.new(limits: [max_value_bytes: 32_768, max_wall_ms: 30_000, max_steps: 10_000])

      {elapsed_us, result} =
        bounded_exec_timed(
          bash,
          "v=a; r=a; for i in {1..15}; do v=${v}${v}; r=${r}${r}; done; v=${v//a/$r}"
        )

      assert result.exit_code == 1
      assert result.stderr =~ "value size limit exceeded (32768 bytes)"
      assert elapsed_us < 200_000
    end

    test "a single pattern replacement that would grow past the cap is refused" do
      bash = JustBash.new(limits: [max_value_bytes: 10])
      result = bounded_exec(bash, "v=aaa; echo ${v/a/XXXXXXXXXXXX}")

      assert result.exit_code == 1
      assert result.stderr =~ "value size limit exceeded (10 bytes)"
    end

    test "a normal-size pattern replacement is untouched" do
      bash = JustBash.new(limits: [max_value_bytes: 1_000])
      result = bounded_exec(bash, ~s(v="hello hello"; echo "${v/hello/hi}" "${v//hello/hi}"))

      assert result.exit_code == 0
      assert result.stdout == "hi hello hi hi\n"
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
          {"cp -r", "cp -r /tree /copy"},
          # Glob expansion descends the tree itself, one directory read per
          # wildcard segment, and is the one traversal that happens before a
          # command is even chosen. Unbounded, this one runs ~295 ms.
          {"glob expansion", "echo /tree/*/*/*"}
        ] do
      test "#{command} is bounded by the wall clock", %{bash: bash} do
        {elapsed_us, {result, _bash}} =
          :timer.tc(fn -> JustBash.exec(bash, unquote(script) <> " > /dev/null") end)

        # The exit code is the discriminator — unbounded, each of these returns
        # exit 0 with empty stderr. `elapsed_us` is the overrun guard: the
        # review measured 4.9-8.1 s on a larger tree under a 1 ms budget.
        assert result.exit_code == 1
        assert result.stderr =~ "execution wall clock limit exceeded (50 ms)"
        assert elapsed_us < 1_000_000
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
