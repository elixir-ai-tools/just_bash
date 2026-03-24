defmodule JustBash.Interpreter.Executor.Loop do
  @moduledoc """
  Executes loop constructs: `for`, `while`, `until`.

  Handles:
  - For loops with word expansion
  - While/until loops with condition evaluation
  - Break and continue signals with nesting levels
  - Loop iteration limits (prevents infinite loops)
  """

  alias JustBash.Interpreter.Expansion
  alias JustBash.Limit
  alias JustBash.Result

  @default_max_iterations 10_000

  @type result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer()
        }

  defmodule WhileContext do
    @moduledoc false
    defstruct [:condition, :body, :is_until, :execute_fn]
  end

  defmodule LoopAcc do
    @moduledoc false
    defstruct stdout_io: [], stderr_io: [], exit_code: 0, iterations: 0
  end

  @spec execute_for(JustBash.t(), String.t(), [any()], [any()], function()) ::
          {result(), JustBash.t()}
  def execute_for(bash, variable, words, body, execute_body_fn) do
    expanded_words = Expansion.expand_for_loop_words(bash, words)
    item_count = length(expanded_words)

    JustBash.Telemetry.for_loop_span(variable, item_count, fn ->
      {result, new_bash} =
        execute_for_loop(bash, variable, expanded_words, body, [], [], 0, execute_body_fn)

      {{result, new_bash}, %{iteration_count: item_count, exit_code: result.exit_code}}
    end)
  end

  @spec execute_while(JustBash.t(), [any()], [any()], String.t(), function()) ::
          {result(), JustBash.t()}
  def execute_while(bash, condition, body, stdin, execute_body_fn) do
    bash = maybe_set_stdin(bash, stdin)

    ctx = %WhileContext{
      condition: condition,
      body: body,
      is_until: false,
      execute_fn: execute_body_fn
    }

    JustBash.Telemetry.while_loop_span(false, fn ->
      {result, new_bash} = execute_while_loop(bash, ctx, %LoopAcc{})
      {{result, new_bash}, %{exit_code: result.exit_code}}
    end)
  end

  @spec execute_until(JustBash.t(), [any()], [any()], String.t(), function()) ::
          {result(), JustBash.t()}
  def execute_until(bash, condition, body, stdin, execute_body_fn) do
    bash = maybe_set_stdin(bash, stdin)

    ctx = %WhileContext{
      condition: condition,
      body: body,
      is_until: true,
      execute_fn: execute_body_fn
    }

    JustBash.Telemetry.while_loop_span(true, fn ->
      {result, new_bash} = execute_while_loop(bash, ctx, %LoopAcc{})
      {{result, new_bash}, %{exit_code: result.exit_code}}
    end)
  end

  defp maybe_set_stdin(bash, ""), do: bash
  defp maybe_set_stdin(bash, stdin), do: %{bash | interpreter: %{bash.interpreter | stdin: stdin}}

  # --- For Loop ---

  defp execute_for_loop(bash, _variable, [], _body, stdout_io, stderr_io, exit_code, _exec_fn) do
    {finalize(stdout_io, stderr_io, exit_code), bash}
  end

  defp execute_for_loop(
         bash,
         variable,
         [value | rest],
         body,
         stdout_io,
         stderr_io,
         _exit_code,
         execute_body_fn
       ) do
    bash = Limit.step!(bash)
    new_bash = %{bash | env: Map.put(bash.env, variable, value)}
    {result, body_bash} = execute_body_fn.(new_bash, body)

    new_stdout_io = [stdout_io, result.stdout]
    new_stderr_io = [stderr_io, result.stderr]

    if body_bash.interpreter.halted do
      {finalize(new_stdout_io, new_stderr_io, 1), body_bash}
    else
      case Result.from_map(result).signal do
        {:break, 1} ->
          {finalize(new_stdout_io, new_stderr_io, 0), body_bash}

        {:break, n} when n > 1 ->
          {signal_result(new_stdout_io, new_stderr_io, 0, {:break, n - 1}), body_bash}

        {:continue, 1} ->
          execute_for_loop(
            body_bash,
            variable,
            rest,
            body,
            new_stdout_io,
            new_stderr_io,
            0,
            execute_body_fn
          )

        {:continue, n} when n > 1 ->
          {signal_result(new_stdout_io, new_stderr_io, 0, {:continue, n - 1}), body_bash}

        {:return, _} = sig ->
          {signal_result(new_stdout_io, new_stderr_io, result.exit_code, sig), body_bash}

        nil ->
          execute_for_loop(
            body_bash,
            variable,
            rest,
            body,
            new_stdout_io,
            new_stderr_io,
            result.exit_code,
            execute_body_fn
          )
      end
    end
  end

  # --- While/Until Loop ---

  defp execute_while_loop(bash, ctx, acc) do
    max = Map.get(bash, :max_iterations, @default_max_iterations)

    if acc.iterations >= max do
      {finalize(
         acc.stdout_io,
         [acc.stderr_io, "loop: iteration limit exceeded\n"],
         acc.exit_code
       ), bash}
    else
      execute_while_iteration(bash, ctx, acc)
    end
  end

  defp execute_while_iteration(bash, ctx, acc) do
    bash = Limit.step!(bash)
    {cond_result, cond_bash} = ctx.execute_fn.(bash, ctx.condition)

    new_acc = %{
      acc
      | stdout_io: [acc.stdout_io, cond_result.stdout],
        stderr_io: [acc.stderr_io, cond_result.stderr]
    }

    if cond_bash.interpreter.halted do
      {finalize(new_acc.stdout_io, new_acc.stderr_io, 1), cond_bash}
    else
      execute_while_body(cond_bash, ctx, new_acc, cond_result)
    end
  end

  defp execute_while_body(cond_bash, ctx, acc, cond_result) do
    should_continue =
      if ctx.is_until, do: cond_result.exit_code != 0, else: cond_result.exit_code == 0

    if should_continue do
      {body_result, body_bash} = ctx.execute_fn.(cond_bash, ctx.body)

      body_acc = %{
        acc
        | stdout_io: [acc.stdout_io, body_result.stdout],
          stderr_io: [acc.stderr_io, body_result.stderr]
      }

      if body_bash.interpreter.halted do
        {finalize(body_acc.stdout_io, body_acc.stderr_io, 1), body_bash}
      else
        handle_while_signal(
          Result.from_map(body_result).signal,
          body_bash,
          ctx,
          acc,
          body_acc,
          body_result
        )
      end
    else
      {finalize(acc.stdout_io, acc.stderr_io, acc.exit_code), cond_bash}
    end
  end

  defp handle_while_signal({:break, 1}, bash, _, _, acc, _) do
    {finalize(acc.stdout_io, acc.stderr_io, 0), bash}
  end

  defp handle_while_signal({:break, n}, bash, _, _, acc, _) when n > 1 do
    {signal_result(acc.stdout_io, acc.stderr_io, 0, {:break, n - 1}), bash}
  end

  defp handle_while_signal({:continue, 1}, bash, ctx, outer_acc, body_acc, _) do
    execute_while_loop(bash, ctx, %{body_acc | exit_code: 0, iterations: outer_acc.iterations + 1})
  end

  defp handle_while_signal({:continue, n}, bash, _, _, acc, _) when n > 1 do
    {signal_result(acc.stdout_io, acc.stderr_io, 0, {:continue, n - 1}), bash}
  end

  defp handle_while_signal({:return, _} = sig, bash, _, _, acc, body_result) do
    {signal_result(acc.stdout_io, acc.stderr_io, body_result.exit_code, sig), bash}
  end

  defp handle_while_signal(nil, bash, ctx, outer_acc, body_acc, body_result) do
    next_acc = %{
      body_acc
      | exit_code: body_result.exit_code,
        iterations: outer_acc.iterations + 1
    }

    execute_while_loop(bash, ctx, next_acc)
  end

  # --- Helpers ---

  defp finalize(stdout_io, stderr_io, exit_code) do
    %{
      stdout: IO.iodata_to_binary(stdout_io),
      stderr: IO.iodata_to_binary(stderr_io),
      exit_code: exit_code
    }
  end

  defp signal_result(stdout_io, stderr_io, exit_code, signal) do
    Result.to_map(%Result{
      stdout: IO.iodata_to_binary(stdout_io),
      stderr: IO.iodata_to_binary(stderr_io),
      exit_code: exit_code,
      signal: signal
    })
  end
end
