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
  alias JustBash.Limits
  alias JustBash.Result
  alias JustBash.Security.Policy

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
    max = Policy.get(bash, :max_iterations)
    execute_for_loop(bash, variable, expanded_words, body, [], [], 0, 0, max, execute_body_fn)
  end

  @doc """
  Execute a while loop.
  """
  @spec execute_while(JustBash.t(), [any()], [any()], String.t(), function()) ::
          {result(), JustBash.t()}
  def execute_while(bash, condition, body, stdin, execute_body_fn) do
    bash_with_stdin =
      if stdin != "" do
        %{bash | interpreter: %{bash.interpreter | stdin: stdin}}
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
        %{bash | interpreter: %{bash.interpreter | stdin: stdin}}
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

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp execute_for_loop(
         bash,
         _variable,
         [],
         _body,
         stdout_io,
         stderr_io,
         exit_code,
         _iterations,
         _max,
         _exec_fn
       ) do
    {%{
       stdout: IO.iodata_to_binary(stdout_io),
       stderr: IO.iodata_to_binary(stderr_io),
       exit_code: exit_code
     }, bash}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp execute_for_loop(
         bash,
         variable,
         [value | rest],
         body,
         stdout_io,
         stderr_io,
         exit_code,
         iterations,
         max,
         execute_body_fn
       ) do
    if iterations >= max do
      {%{
         stdout: IO.iodata_to_binary(stdout_io),
         stderr: IO.iodata_to_binary([stderr_io, "loop: iteration limit exceeded\n"]),
         exit_code: exit_code
       }, bash}
    else
      {result, body_bash, new_stdout_io, new_stderr_io, new_iterations} =
        case Limits.put_env(bash, variable, value) do
          {:error, result, new_bash} ->
            {result, new_bash, [stdout_io, result.stdout], [stderr_io, result.stderr], iterations}

          {:ok, new_bash} ->
            {result, body_bash} = execute_body_fn.(new_bash, body)

            {result, body_bash, [stdout_io, result.stdout], [stderr_io, result.stderr],
             iterations + 1}
        end

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
          if Limits.limit_error?(body_bash) do
            {%{
               stdout: IO.iodata_to_binary(new_stdout_io),
               stderr: IO.iodata_to_binary(new_stderr_io),
               exit_code: result.exit_code
             }, body_bash}
          else
            execute_for_loop(
              body_bash,
              variable,
              rest,
              body,
              new_stdout_io,
              new_stderr_io,
              0,
              new_iterations,
              max,
              execute_body_fn
            )
          end

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
          if Limits.limit_error?(body_bash) do
            {%{
               stdout: IO.iodata_to_binary(new_stdout_io),
               stderr: IO.iodata_to_binary(new_stderr_io),
               exit_code: result.exit_code
             }, body_bash}
          else
            execute_for_loop(
              body_bash,
              variable,
              rest,
              body,
              new_stdout_io,
              new_stderr_io,
              result.exit_code,
              new_iterations,
              max,
              execute_body_fn
            )
          end

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
  end

  # --- While/Until Loop Implementation ---

  defp execute_while_loop(bash, ctx, acc) do
    max = Policy.get(bash, :max_iterations)

    if acc.iterations >= max do
      {%{
         stdout: IO.iodata_to_binary(acc.stdout_io),
         stderr: IO.iodata_to_binary([acc.stderr_io, "loop: iteration limit exceeded\n"]),
         exit_code: acc.exit_code
       }, bash}
    else
      execute_while_iteration(bash, ctx, acc)
    end
  end

  defp execute_while_iteration(bash, ctx, acc) do
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

    if Limits.limit_error?(cond_bash) do
      {%{
         stdout: IO.iodata_to_binary(new_acc.stdout_io),
         stderr: IO.iodata_to_binary(new_acc.stderr_io),
         exit_code: cond_result.exit_code
       }, cond_bash}
    else
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
            continue_while_loop(
              body_bash,
              ctx,
              body_acc,
              0,
              body_result.exit_code,
              acc.iterations
            )

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
            continue_while_loop(
              body_bash,
              ctx,
              body_acc,
              body_result.exit_code,
              body_result.exit_code,
              acc.iterations
            )
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

  defp continue_while_loop(body_bash, ctx, body_acc, next_exit_code, error_exit_code, iterations) do
    if Limits.limit_error?(body_bash) do
      {%{
         stdout: IO.iodata_to_binary(body_acc.stdout_io),
         stderr: IO.iodata_to_binary(body_acc.stderr_io),
         exit_code: error_exit_code
       }, body_bash}
    else
      next_acc = %{body_acc | exit_code: next_exit_code, iterations: iterations + 1}
      execute_while_loop(body_bash, ctx, next_acc)
    end
  end
end
