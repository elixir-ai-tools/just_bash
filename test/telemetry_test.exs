defmodule JustBash.TelemetryTest do
  use ExUnit.Case, async: true

  def handle_event(event, measurements, metadata, {ref, pid}) do
    send(pid, {ref, event, measurements, metadata})
  end

  setup do
    ref = make_ref()
    pid = self()

    events = [
      [:just_bash, :session, :run, :start],
      [:just_bash, :session, :run, :stop],
      [:just_bash, :session, :run, :exception],
      [:just_bash, :command, :start],
      [:just_bash, :command, :stop],
      [:just_bash, :command, :exception],
      [:just_bash, :for_loop, :start],
      [:just_bash, :for_loop, :stop],
      [:just_bash, :for_loop, :exception],
      [:just_bash, :while_loop, :start],
      [:just_bash, :while_loop, :stop],
      [:just_bash, :while_loop, :exception]
    ]

    handler_id = "telemetry-test-#{inspect(ref)}"
    :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, {ref, pid})
    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{ref: ref}
  end

  describe "session span" do
    test "emits start and stop events for exec/2", %{ref: ref} do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "echo hello")

      assert result.stdout == "hello\n"
      assert result.exit_code == 0

      assert_receive {^ref, [:just_bash, :session, :run, :start], %{system_time: _},
                      %{session: pid}}

      assert is_pid(pid)

      assert_receive {^ref, [:just_bash, :session, :run, :stop], %{duration: duration},
                      %{
                        session: ^pid,
                        status: :ok,
                        exit_code: 0,
                        bytes_in: bytes_in,
                        bytes_out: bytes_out
                      }}

      assert is_integer(duration)
      assert duration >= 0
      assert bytes_in == byte_size("echo hello")
      assert bytes_out == byte_size("hello\n")
    end

    test "emits start and stop events for exec!/2", %{ref: ref} do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec!(bash, "echo hello")

      assert result.stdout == "hello\n"

      assert_receive {^ref, [:just_bash, :session, :run, :start], _, %{session: _}}

      assert_receive {^ref, [:just_bash, :session, :run, :stop], _,
                      %{status: :ok, exit_code: 0, bytes_in: 10, bytes_out: 6}}
    end

    test "reports error status on parse failure", %{ref: ref} do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "if then")

      assert result.exit_code == 2

      assert_receive {^ref, [:just_bash, :session, :run, :start], _, _}

      assert_receive {^ref, [:just_bash, :session, :run, :stop], _,
                      %{status: :error, exit_code: 2, bytes_in: 7, bytes_out: bytes_out}}

      assert bytes_out > 0
    end

    test "emits exception event when exec! raises", %{ref: ref} do
      bash = JustBash.new()

      assert_raise RuntimeError, ~r/Parse error/, fn ->
        JustBash.exec!(bash, "if then")
      end

      assert_receive {^ref, [:just_bash, :session, :run, :start], _, _}

      assert_receive {^ref, [:just_bash, :session, :run, :exception], %{duration: _},
                      %{kind: :error, reason: %RuntimeError{}, stacktrace: stacktrace}}

      assert is_list(stacktrace)
    end

    test "includes bytes for multi-command scripts", %{ref: ref} do
      bash = JustBash.new()
      script = "echo hello; echo world"
      {result, _bash} = JustBash.exec(bash, script)

      assert_receive {^ref, [:just_bash, :session, :run, :stop], _,
                      %{bytes_in: bytes_in, bytes_out: bytes_out}}

      assert bytes_in == byte_size(script)
      assert bytes_out == byte_size(result.stdout) + byte_size(result.stderr)
    end
  end

  describe "command span" do
    test "emits events for builtin commands with bytes", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "echo hello world")

      assert_receive {^ref, [:just_bash, :command, :start], %{system_time: _},
                      %{command: "echo", args: ["hello", "world"]}}

      assert_receive {^ref, [:just_bash, :command, :stop], %{duration: _},
                      %{
                        command: "echo",
                        args: ["hello", "world"],
                        exit_code: 0,
                        bytes_in: 0,
                        bytes_out: bytes_out
                      }}

      # "hello world\n"
      assert bytes_out == 12
    end

    test "reports bytes_in from stdin in pipeline", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "echo hello | cat")

      # cat receives "hello\n" as stdin
      assert_receive {^ref, [:just_bash, :command, :stop], _,
                      %{command: "cat", bytes_in: 6, bytes_out: 6}}
    end

    test "reports exit code for failing commands", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "cat nonexistent")

      assert_receive {^ref, [:just_bash, :command, :stop], _,
                      %{command: "cat", exit_code: 1, bytes_out: bytes_out}}

      assert bytes_out > 0
    end

    test "emits events for each command in a pipeline", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "echo hello | cat")

      assert_receive {^ref, [:just_bash, :command, :start], _, %{command: "echo"}}
      assert_receive {^ref, [:just_bash, :command, :stop], _, %{command: "echo"}}
      assert_receive {^ref, [:just_bash, :command, :start], _, %{command: "cat"}}
      assert_receive {^ref, [:just_bash, :command, :stop], _, %{command: "cat"}}
    end

    test "does not emit events for shell functions", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "greet() { echo hi; }; greet")

      # Should see the inner echo command but not "greet" as a command span
      assert_receive {^ref, [:just_bash, :command, :start], _, %{command: "echo"}}
      assert_receive {^ref, [:just_bash, :command, :stop], _, %{command: "echo"}}
      refute_received {^ref, [:just_bash, :command, :start], _, %{command: "greet"}}
    end

    test "reports exit code 127 for unknown commands", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "nonexistent_command")

      assert_receive {^ref, [:just_bash, :command, :stop], _,
                      %{command: "nonexistent_command", exit_code: 127}}
    end
  end

  describe "for loop span" do
    test "emits events with variable and item count", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "for i in a b c; do echo $i; done")

      assert_receive {^ref, [:just_bash, :for_loop, :start], %{system_time: _},
                      %{variable: "i", item_count: 3}}

      assert_receive {^ref, [:just_bash, :for_loop, :stop], %{duration: _},
                      %{variable: "i", item_count: 3, iteration_count: 3, exit_code: 0}}
    end

    test "emits events for empty word list", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "for i in; do echo $i; done")

      assert_receive {^ref, [:just_bash, :for_loop, :start], _, %{variable: "i", item_count: 0}}

      assert_receive {^ref, [:just_bash, :for_loop, :stop], _,
                      %{item_count: 0, iteration_count: 0}}
    end
  end

  describe "while loop span" do
    test "emits events for while loop", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "x=0; while [ $x -lt 3 ]; do x=$((x+1)); done")

      assert_receive {^ref, [:just_bash, :while_loop, :start], %{system_time: _}, %{until: false}}

      assert_receive {^ref, [:just_bash, :while_loop, :stop], %{duration: _},
                      %{until: false, exit_code: 0}}
    end

    test "emits events for until loop with until: true", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "x=0; until [ $x -ge 2 ]; do x=$((x+1)); done")

      assert_receive {^ref, [:just_bash, :while_loop, :start], _, %{until: true}}

      assert_receive {^ref, [:just_bash, :while_loop, :stop], %{duration: _},
                      %{until: true, exit_code: 0}}
    end

    test "reports zero iterations when condition is false immediately", %{ref: ref} do
      bash = JustBash.new()
      JustBash.exec(bash, "while false; do echo nope; done")

      assert_receive {^ref, [:just_bash, :while_loop, :stop], _, %{exit_code: 0}}
    end
  end
end
