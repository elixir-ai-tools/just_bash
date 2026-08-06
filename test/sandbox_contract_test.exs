defmodule JustBash.SandboxContractTest do
  @moduledoc """
  The two guarantees `JustBash.exec/2` owes a host that runs untrusted script
  text: it returns, and it returns a shell-shaped result rather than raising.

  See issue #69.
  """

  use ExUnit.Case, async: true

  alias JustBash.FS
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

    test "bounds a traversal, which the step counter charges as a single step" do
      # `find` never returned through a symlink cycle (#53). The cycle is gone,
      # but nothing structural stopped the next one — a whole tree walk is one
      # step, so only the wall clock can bound it.
      files = for i <- 1..1000, into: %{}, do: {"/tree/#{rem(i, 10)}/#{i}/f.txt", "x"}
      bash = JustBash.new(files: files, limits: [max_wall_ms: 1, max_steps: 10_000_000])

      {result, _bash} = JustBash.exec(bash, "find /tree")

      assert result.exit_code == 1
      assert result.stderr =~ "execution wall clock limit exceeded (1 ms)"
    end

    test "rejects a non-positive value like every other bound" do
      assert_raise ArgumentError, ~r/positive integers/, fn ->
        Limit.new(max_wall_ms: 0)
      end
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

  describe "FS.walk/3 deadline" do
    setup do
      fs =
        Enum.reduce(1..20, FS.new(), fn i, acc ->
          {:ok, acc} = FS.mkdir(acc, "/d/#{i}", parents: true)
          {:ok, acc} = FS.write_file(acc, "/d/#{i}/f", "x")
          acc
        end)

      {:ok, fs: fs}
    end

    test "walks normally without a deadline", %{fs: fs} do
      assert fs |> FS.walk("/d") |> Enum.count() == 20
    end

    test "walks normally with a deadline that has not passed", %{fs: fs} do
      deadline = Limit.deadline(Limit.new(max_wall_ms: 10_000))
      assert fs |> FS.walk("/d", deadline: deadline) |> Enum.count() == 20
    end

    test "raises once the deadline has passed", %{fs: fs} do
      expired = Limit.deadline(Limit.new(max_wall_ms: 1))
      Process.sleep(5)

      assert_raise Limit.ExceededError, ~r/wall clock limit exceeded/, fn ->
        fs |> FS.walk("/d", deadline: expired) |> Enum.to_list()
      end
    end
  end
end
