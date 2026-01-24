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
  alias JustBash.Result

  @max_iterations 1000

  @type result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer()
        }

  # Context struct for while/until loops to reduce function arity
  defmodule WhileContext do
    @moduledoc false
    defstruct [:condition, :body, :is_until, :execute_fn]
  end

  # Accumulator struct for loop state
  defmodule LoopAcc do
    @moduledoc false
    defstruct stdout_io: [], stderr_io: [], exit_code: 0, iterations: 0
  end

  @doc """
  Execute a for loop over expanded words.
  """
  @spec execute_for(JustBash.t(), String.t(), [any()], [any()], function()) ::
          {result(), JustBash.t()}
  def execute_for(bash, variable, words, body, execute_body_fn) do
    expanded_words = Expansion.expand_for_loop_words(bash, words)
    execute_for_loop(bash, variable, expanded_words, body, [], [], 0, execute_body_fn)
  end

  @doc """
  Execute a while loop.
  """
  @spec execute_while(JustBash.t(), [any()], [any()], String.t(), function()) ::
          {result(), JustBash.t()}
  def execute_while(bash, condition, body, stdin, execute_body_fn) do
    bash_with_stdin =
      if stdin != "" do
        %{bash | env: Map.put(bash.env, "__STDIN__", stdin)}
      else
        bash
      end

    ctx = %WhileContext{
      condition: condition,
      body: body,
      is_until: false,
      execute_fn: execute_body_fn
    }

    execute_while_loop(bash_with_stdin, ctx, %LoopAcc{})
  end

  @doc """
  Execute an until loop (while with inverted condition).
  """
  @spec execute_until(JustBash.t(), [any()], [any()], String.t(), function()) ::
          {result(), JustBash.t()}
  def execute_until(bash, condition, body, stdin, execute_body_fn) do
    bash_with_stdin =
      if stdin != "" do
        %{bash | env: Map.put(bash.env, "__STDIN__", stdin)}
      else
        bash
      end

    ctx = %WhileContext{
      condition: condition,
      body: body,
      is_until: true,
      execute_fn: execute_body_fn
    }

    execute_while_loop(bash_with_stdin, ctx, %LoopAcc{})
  end

  # --- For Loop Implementation ---

  defp execute_for_loop(bash, _variable, [], _body, stdout_io, stderr_io, exit_code, _exec_fn) do
    {%{
       stdout: IO.iodata_to_binary(stdout_io),
       stderr: IO.iodata_to_binary(stderr_io),
       exit_code: exit_code
     }, bash}
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
    new_bash = %{bash | env: Map.put(bash.env, variable, value)}
    {result, body_bash} = execute_body_fn.(new_bash, body)
    new_stdout_io = [stdout_io, result.stdout]
    new_stderr_io = [stderr_io, result.stderr]

    # Use Result struct for type-safe signal handling
    case Result.from_map(result).signal do
      # Break level 1: exit loop with accumulated output
      {:break, 1} ->
        {%{
           stdout: IO.iodata_to_binary(new_stdout_io),
           stderr: IO.iodata_to_binary(new_stderr_io),
           exit_code: 0
         }, body_bash}

      # Break with level > 1: propagate to outer loop with decremented level
      {:break, n} when n > 1 ->
        {Result.to_map(%Result{
           stdout: IO.iodata_to_binary(new_stdout_io),
           stderr: IO.iodata_to_binary(new_stderr_io),
           exit_code: 0,
           signal: {:break, n - 1}
         }), body_bash}

      # Continue level 1: skip to next iteration
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

      # Continue with level > 1: propagate to outer loop with decremented level
      {:continue, n} when n > 1 ->
        {Result.to_map(%Result{
           stdout: IO.iodata_to_binary(new_stdout_io),
           stderr: IO.iodata_to_binary(new_stderr_io),
           exit_code: 0,
           signal: {:continue, n - 1}
         }), body_bash}

      # No signal: continue to next iteration
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

      # Return signal: propagate as-is
      {:return, _} = signal ->
        {Result.to_map(%Result{
           stdout: IO.iodata_to_binary(new_stdout_io),
           stderr: IO.iodata_to_binary(new_stderr_io),
           exit_code: result.exit_code,
           signal: signal
         }), body_bash}
    end
  end

  # --- While/Until Loop Implementation ---

  defp execute_while_loop(bash, _ctx, %LoopAcc{iterations: iterations} = acc)
       when iterations >= @max_iterations do
    {%{
       stdout: IO.iodata_to_binary(acc.stdout_io),
       stderr: IO.iodata_to_binary([acc.stderr_io, "loop: iteration limit exceeded\n"]),
       exit_code: acc.exit_code
     }, bash}
  end

  defp execute_while_loop(bash, ctx, acc) do
    {cond_result, cond_bash} = ctx.execute_fn.(bash, ctx.condition)

    should_continue =
      if ctx.is_until do
        cond_result.exit_code != 0
      else
        cond_result.exit_code == 0
      end

    new_acc = %{
      acc
      | stdout_io: [acc.stdout_io, cond_result.stdout],
        stderr_io: [acc.stderr_io, cond_result.stderr]
    }

    if should_continue do
      {body_result, body_bash} = ctx.execute_fn.(cond_bash, ctx.body)

      body_acc = %{
        new_acc
        | stdout_io: [new_acc.stdout_io, body_result.stdout],
          stderr_io: [new_acc.stderr_io, body_result.stderr]
      }

      # Use Result struct for type-safe signal handling
      case Result.from_map(body_result).signal do
        # Break level 1: exit loop
        {:break, 1} ->
          {%{
             stdout: IO.iodata_to_binary(body_acc.stdout_io),
             stderr: IO.iodata_to_binary(body_acc.stderr_io),
             exit_code: 0
           }, body_bash}

        # Break with level > 1: propagate with decremented level
        {:break, n} when n > 1 ->
          {Result.to_map(%Result{
             stdout: IO.iodata_to_binary(body_acc.stdout_io),
             stderr: IO.iodata_to_binary(body_acc.stderr_io),
             exit_code: 0,
             signal: {:break, n - 1}
           }), body_bash}

        # Continue level 1: re-check condition
        {:continue, 1} ->
          next_acc = %{body_acc | exit_code: 0, iterations: acc.iterations + 1}
          execute_while_loop(body_bash, ctx, next_acc)

        # Continue with level > 1: propagate with decremented level
        {:continue, n} when n > 1 ->
          {Result.to_map(%Result{
             stdout: IO.iodata_to_binary(body_acc.stdout_io),
             stderr: IO.iodata_to_binary(body_acc.stderr_io),
             exit_code: 0,
             signal: {:continue, n - 1}
           }), body_bash}

        # Return signal: propagate as-is
        {:return, _} = signal ->
          {Result.to_map(%Result{
             stdout: IO.iodata_to_binary(body_acc.stdout_io),
             stderr: IO.iodata_to_binary(body_acc.stderr_io),
             exit_code: body_result.exit_code,
             signal: signal
           }), body_bash}

        # No signal: continue loop
        nil ->
          next_acc = %{
            body_acc
            | exit_code: body_result.exit_code,
              iterations: acc.iterations + 1
          }

          execute_while_loop(body_bash, ctx, next_acc)
      end
    else
      {%{
         stdout: IO.iodata_to_binary(new_acc.stdout_io),
         stderr: IO.iodata_to_binary(new_acc.stderr_io),
         exit_code: acc.exit_code
       }, cond_bash}
    end
  end
end
