defmodule JustBash.Interpreter.Executor do
  @moduledoc """
  Executes parsed bash AST nodes.

  This is the main entry point for script execution. Complex functionality
  is delegated to submodules:

  - `Executor.Conditional` - [[ ]] and if/case evaluation
  - `Executor.Loop` - for/while/until loops
  - `Executor.Redirection` - File redirections (>, >>, <, etc.)
  """

  alias JustBash.AST
  alias JustBash.Commands.Registry
  alias JustBash.Interpreter.Executor.Conditional
  alias JustBash.Interpreter.Executor.Loop
  alias JustBash.Interpreter.Executor.Redirection
  alias JustBash.Interpreter.Expansion
  alias JustBash.Result

  @type result :: %{
          :stdout => String.t(),
          :stderr => String.t(),
          :exit_code => non_neg_integer(),
          optional(:env) => map()
        }

  @doc """
  Execute a parsed script AST.
  Returns {result, updated_bash}.
  """
  @spec execute_script(JustBash.t(), AST.Script.t()) :: {result(), JustBash.t()}
  def execute_script(bash, %AST.Script{statements: statements}) do
    {final_bash, stdout_io, stderr_io, exit_code, _halted} =
      Enum.reduce_while(statements, {bash, [], [], 0, false}, fn stmt, {b, out, err, _code, _} ->
        {result, new_bash} = execute_statement(b, stmt)
        new_env = Map.put(new_bash.env, "?", to_string(result.exit_code))
        new_bash = %{new_bash | last_exit_code: result.exit_code, env: new_env}
        # Use iodata - O(1) prepend, single flatten at end
        acc = {new_bash, [out, result.stdout], [err, result.stderr], result.exit_code, false}

        # Check errexit: exit if enabled and command failed
        # Note: errexit doesn't apply to statements with && or || operators
        if new_bash.shell_opts.errexit and result.exit_code != 0 and
             not has_short_circuit_operators?(stmt) do
          {:halt, put_elem(acc, 4, true)}
        else
          {:cont, acc}
        end
      end)

    result = %{
      stdout: IO.iodata_to_binary(stdout_io),
      stderr: IO.iodata_to_binary(stderr_io),
      exit_code: exit_code,
      env: final_bash.env
    }

    {result, final_bash}
  end

  # Check if statement uses && or || operators (errexit doesn't apply to these)
  defp has_short_circuit_operators?(%AST.Statement{operators: operators}) do
    Enum.any?(operators, &(&1 in [:and, :or]))
  end

  @doc """
  Execute a statement (one or more pipelines with && or ||).
  """
  @spec execute_statement(JustBash.t(), AST.Statement.t() | AST.Group.t()) ::
          {result(), JustBash.t()}
  def execute_statement(bash, %AST.Statement{pipelines: pipelines, operators: operators}) do
    execute_pipelines(bash, pipelines, operators, 0, [], [], nil)
  end

  def execute_statement(bash, %AST.Group{body: body}) do
    execute_body_with_bash(bash, body)
  end

  # Use iodata for stdout/stderr accumulation
  defp execute_pipelines(bash, pipelines, operators, prev_exit, stdout_io, stderr_io, prev_op) do
    execute_pipelines(bash, pipelines, operators, prev_exit, stdout_io, stderr_io, prev_op, nil)
  end

  defp execute_pipelines(bash, [], _operators, exit_code, stdout_io, stderr_io, _prev_op, control) do
    result = %{
      stdout: IO.iodata_to_binary(stdout_io),
      stderr: IO.iodata_to_binary(stderr_io),
      exit_code: exit_code
    }

    result = add_control_signal(result, control)
    {result, bash}
  end

  defp execute_pipelines(
         bash,
         [pipeline | rest],
         operators,
         prev_exit,
         stdout_io,
         stderr_io,
         prev_op,
         control
       ) do
    # If we have a pending break/continue, stop immediately
    if control != nil do
      execute_pipelines(bash, [], operators, prev_exit, stdout_io, stderr_io, prev_op, control)
    else
      should_run =
        case prev_op do
          nil -> true
          :and -> prev_exit == 0
          :or -> prev_exit != 0
          :semicolon -> true
        end

      {next_op, next_operators} = advance_operators(operators)

      if should_run do
        {result, new_bash} = execute_pipeline(bash, pipeline)

        # Check for control signals using Result struct for type safety
        new_control = extract_control_signal(result)

        execute_pipelines(
          new_bash,
          rest,
          next_operators,
          result.exit_code,
          [stdout_io, result.stdout],
          [stderr_io, result.stderr],
          next_op,
          new_control
        )
      else
        execute_pipelines(
          bash,
          rest,
          next_operators,
          prev_exit,
          stdout_io,
          stderr_io,
          next_op,
          nil
        )
      end
    end
  end

  defp add_control_signal(result, nil), do: result
  defp add_control_signal(result, {:break, n}), do: Map.put(result, :__break__, n)
  defp add_control_signal(result, {:continue, n}), do: Map.put(result, :__continue__, n)
  defp add_control_signal(result, {:return, n}), do: Map.put(result, :__return__, n)

  # Extract control signal from a result map using Result struct for type safety
  defp extract_control_signal(result) do
    Result.from_map(result).signal
  end

  defp advance_operators([op | rest]), do: {op, rest}
  defp advance_operators([]), do: {nil, []}

  @doc """
  Execute a pipeline (commands connected by |).
  """
  @spec execute_pipeline(JustBash.t(), AST.Pipeline.t()) :: {result(), JustBash.t()}
  def execute_pipeline(bash, %AST.Pipeline{commands: commands, negated: negated}) do
    # Track all exit codes for pipefail (prepend for O(1), reverse at end)
    {final_result, final_bash, exit_codes_reversed} =
      Enum.reduce(commands, {%{stdout: "", stderr: "", exit_code: 0}, bash, []}, fn cmd,
                                                                                    {prev_result,
                                                                                     current_bash,
                                                                                     codes} ->
        {result, new_bash} = execute_command(current_bash, cmd, prev_result.stdout)
        {result, new_bash, [result.exit_code | codes]}
      end)

    exit_codes = Enum.reverse(exit_codes_reversed)

    # With pipefail, return the rightmost non-zero exit code
    # Without pipefail, return the last command's exit code
    pipeline_exit =
      if bash.shell_opts.pipefail do
        Enum.find(Enum.reverse(exit_codes), 0, &(&1 != 0))
      else
        final_result.exit_code
      end

    exit_code =
      if negated do
        if pipeline_exit == 0, do: 1, else: 0
      else
        pipeline_exit
      end

    {%{final_result | exit_code: exit_code}, final_bash}
  end

  @doc """
  Execute a single command.
  """
  @spec execute_command(JustBash.t(), AST.command(), String.t()) :: {result(), JustBash.t()}
  def execute_command(bash, command, stdin \\ "")

  def execute_command(bash, %AST.SimpleCommand{name: nil, assignments: assignments}, _stdin) do
    new_bash = execute_assignments(bash, assignments)
    {%{stdout: "", stderr: "", exit_code: 0}, new_bash}
  end

  def execute_command(
        bash,
        %AST.SimpleCommand{
          name: name,
          args: args,
          assignments: assignments,
          redirections: redirs
        },
        stdin
      ) do
    do_execute_simple_command(bash, name, args, assignments, redirs, stdin)
  end

  def execute_command(bash, %AST.If{clauses: clauses, else_body: else_body}, _stdin),
    do: execute_if(bash, clauses, else_body)

  def execute_command(bash, %AST.For{variable: variable, words: words, body: body}, _stdin) do
    Loop.execute_for(bash, variable, words, body, &execute_body/2)
  end

  def execute_command(bash, %AST.While{condition: condition, body: body}, stdin) do
    Loop.execute_while(bash, condition, body, stdin, &execute_body/2)
  end

  def execute_command(bash, %AST.Until{condition: condition, body: body}, stdin) do
    Loop.execute_until(bash, condition, body, stdin, &execute_body/2)
  end

  def execute_command(bash, %AST.Case{word: word, items: items}, _stdin) do
    value = Expansion.expand_word_parts_simple(bash, word.parts)
    execute_case(bash, value, items)
  end

  def execute_command(bash, %AST.Subshell{body: body}, _stdin) do
    {result, _subshell_bash} = execute_body(bash, body)
    {result, bash}
  end

  def execute_command(bash, %AST.Group{body: body}, stdin) do
    execute_body_with_stdin(bash, body, stdin)
  end

  def execute_command(bash, %AST.FunctionDef{name: name, body: body}, _stdin) do
    new_bash = %{bash | functions: Map.put(bash.functions, name, body)}
    {%{stdout: "", stderr: "", exit_code: 0}, new_bash}
  end

  def execute_command(bash, %AST.ArithmeticCommand{expression: expr}, _stdin) do
    {value, new_env} = JustBash.Arithmetic.evaluate(expr.expression, bash.env)
    new_bash = %{bash | env: new_env}
    exit_code = if value == 0, do: 1, else: 0
    {%{stdout: "", stderr: "", exit_code: exit_code}, new_bash}
  end

  def execute_command(bash, %AST.ConditionalCommand{expression: expr}, _stdin) do
    result = Conditional.evaluate(bash, expr)
    exit_code = if result, do: 0, else: 1
    {%{stdout: "", stderr: "", exit_code: exit_code}, bash}
  end

  def execute_command(bash, _command, _stdin),
    do: {%{stdout: "", stderr: "", exit_code: 0}, bash}

  # --- Simple Command Execution (with implicit try for UnsetVariableError) ---

  defp do_execute_simple_command(bash, name, args, assignments, redirs, stdin) do
    temp_bash = execute_assignments(bash, assignments)
    {cmd_name, cmd_assigns} = Expansion.expand_word_parts(temp_bash, name.parts)

    # Apply any assignments from ${VAR:=default} expansions
    temp_bash = apply_pending_assignments(temp_bash, cmd_assigns)

    # Expand args sequentially, applying any assignments between each
    # This ensures side effects like $((x++)) are visible to subsequent args
    # Use prepend for O(1) and reverse at end for correct order
    {expanded_args_reversed, temp_bash} =
      Enum.reduce(args, {[], temp_bash}, fn arg, {acc, current_bash} ->
        {expanded, arg_assigns} = Expansion.expand_word_with_glob(current_bash, arg.parts)
        current_bash = apply_pending_assignments(current_bash, arg_assigns)
        # Prepend expanded (which is a list) reversed, so final reverse gives correct order
        {Enum.reverse(expanded) ++ acc, current_bash}
      end)

    expanded_args = Enum.reverse(expanded_args_reversed)

    # Extract heredoc content as stdin if present
    {heredoc_stdin, non_heredoc_redirs} = Redirection.extract_heredoc_stdin(temp_bash, redirs)
    effective_stdin = heredoc_stdin || stdin

    {result, exec_bash} =
      case Map.get(temp_bash.functions, cmd_name) do
        nil ->
          execute_builtin(temp_bash, cmd_name, expanded_args, effective_stdin)

        func_body ->
          execute_function(temp_bash, func_body, expanded_args)
      end

    Redirection.apply_redirections(result, exec_bash, non_heredoc_redirs)
  rescue
    e in Expansion.UnsetVariableError ->
      {%{stdout: "", stderr: "bash: #{Exception.message(e)}\n", exit_code: 1}, bash}
  end

  # --- If/Case Execution ---

  defp execute_if(bash, [], else_body) do
    if else_body do
      execute_body_with_bash(bash, else_body)
    else
      {%{stdout: "", stderr: "", exit_code: 0}, bash}
    end
  end

  defp execute_if(bash, [%AST.IfClause{condition: condition, body: body} | rest], else_body) do
    {cond_result, cond_bash} = execute_body(bash, condition)

    if cond_result.exit_code == 0 do
      {body_result, new_bash} = execute_body_with_bash(cond_bash, body)

      result = %{
        body_result
        | stdout: cond_result.stdout <> body_result.stdout,
          stderr: cond_result.stderr <> body_result.stderr
      }

      # Propagate break/continue signals
      result = propagate_control_signals(body_result, result)
      {result, new_bash}
    else
      {else_result, new_bash} = execute_if(cond_bash, rest, else_body)

      result = %{
        else_result
        | stdout: cond_result.stdout <> else_result.stdout,
          stderr: cond_result.stderr <> else_result.stderr
      }

      # Propagate break/continue signals
      result = propagate_control_signals(else_result, result)
      {result, new_bash}
    end
  end

  # Helper to propagate control signals from source to target result
  # Uses Result struct for type-safe signal extraction
  defp propagate_control_signals(source, target) do
    case extract_control_signal(source) do
      nil -> target
      signal -> add_control_signal(target, signal)
    end
  end

  # --- Case Execution ---

  defp execute_case(bash, _value, []) do
    {%{stdout: "", stderr: "", exit_code: 0}, bash}
  end

  defp execute_case(bash, value, [%AST.CaseItem{patterns: patterns, body: body} | rest]) do
    matches? =
      Enum.any?(patterns, fn pattern ->
        pattern_str = Expansion.expand_word_parts_simple(bash, pattern.parts)
        match_pattern?(value, pattern_str)
      end)

    if matches? do
      execute_body_with_bash(bash, body)
    else
      execute_case(bash, value, rest)
    end
  end

  defp match_pattern?(_value, "*"), do: true

  defp match_pattern?(value, pattern) do
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/^#{regex_pattern}$/, value)
  end

  defp execute_body(bash, statements) do
    {final_bash, stdout, stderr, exit_code, control} =
      Enum.reduce_while(statements, {bash, "", "", 0, nil}, fn stmt,
                                                               {b, out, err, _code, _ctrl} ->
        {result, new_bash} = execute_statement(b, stmt)
        new_out = out <> result.stdout
        new_err = err <> result.stderr

        # Check for control flow signals using Result struct
        case extract_control_signal(result) do
          {:break, n} ->
            {:halt, {new_bash, new_out, new_err, 0, {:break, n}}}

          {:continue, n} ->
            {:halt, {new_bash, new_out, new_err, 0, {:continue, n}}}

          {:return, n} ->
            {:halt, {new_bash, new_out, new_err, n, {:return, n}}}

          nil ->
            {:cont, {new_bash, new_out, new_err, result.exit_code, nil}}
        end
      end)

    result = %{stdout: stdout, stderr: stderr, exit_code: exit_code, env: final_bash.env}

    # Propagate control flow signals using add_control_signal helper
    result = add_control_signal(result, control)

    {result, final_bash}
  end

  defp execute_body_with_bash(bash, statements) do
    {result, new_bash} = execute_body(bash, statements)
    # Preserve break/continue signals
    new_result = %{stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code}
    new_result = propagate_control_signals(result, new_result)
    {new_result, new_bash}
  end

  # Execute body with stdin available for the first command in the first pipeline
  defp execute_body_with_stdin(bash, [], _stdin) do
    {%{stdout: "", stderr: "", exit_code: 0}, bash}
  end

  defp execute_body_with_stdin(bash, statements, stdin) do
    # Store stdin in bash env temporarily for commands to consume
    stdin_bash = %{bash | env: Map.put(bash.env, "__STDIN__", stdin)}
    {result, new_bash} = execute_body(stdin_bash, statements)
    # Remove the temporary stdin
    final_bash = %{new_bash | env: Map.delete(new_bash.env, "__STDIN__")}
    {%{stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code}, final_bash}
  end

  defp execute_function(bash, body, args) do
    positional_env =
      args
      |> Enum.with_index(1)
      |> Enum.into(%{}, fn {arg, idx} -> {to_string(idx), arg} end)
      |> Map.put("#", to_string(length(args)))
      |> Map.put("@", Enum.join(args, " "))
      |> Map.put("*", Enum.join(args, " "))

    func_bash = %{bash | env: Map.merge(bash.env, positional_env)}
    {result, _func_final_bash} = execute_body(func_bash, [body])
    {%{stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code}, bash}
  end

  defp execute_assignments(bash, assignments) do
    Enum.reduce(assignments, bash, fn %AST.Assignment{name: name, value: value, array: array},
                                      acc ->
      case array do
        nil ->
          # Scalar assignment
          {expanded_value, pending} =
            case value do
              nil -> {"", []}
              %AST.Word{parts: parts} -> Expansion.expand_word_parts(acc, parts)
              _ -> {"", []}
            end

          acc = apply_pending_assignments(acc, pending)
          %{acc | env: Map.put(acc.env, name, expanded_value)}

        elements when is_list(elements) ->
          # Array assignment: arr=(a b c)
          # First, clear any existing array elements for this name
          env =
            acc.env
            |> Enum.reject(fn {key, _} ->
              Regex.match?(~r/^#{Regex.escape(name)}\[\d+\]$/, key)
            end)
            |> Map.new()

          # Store as arr[0], arr[1], etc.
          {env, _idx, acc} =
            Enum.reduce(elements, {env, 0, acc}, fn word, {env_acc, idx, bash_acc} ->
              {expanded, pending} = Expansion.expand_word_parts(bash_acc, word.parts)
              bash_acc = apply_pending_assignments(bash_acc, pending)
              key = "#{name}[#{idx}]"
              {Map.put(env_acc, key, expanded), idx + 1, bash_acc}
            end)

          # Also store arr itself as the first element (bash compat)
          first_element = Map.get(env, "#{name}[0]", "")
          env = Map.put(env, name, first_element)

          %{acc | env: env}
      end
    end)
  end

  # Apply pending variable assignments from expansions like ${VAR:=default} or $((x++))
  defp apply_pending_assignments(bash, []), do: bash

  defp apply_pending_assignments(bash, assignments) do
    Enum.reduce(assignments, bash, fn {name, value}, acc ->
      %{acc | env: Map.put(acc.env, name, value)}
    end)
  end

  defp execute_builtin(bash, cmd, args, stdin) do
    case Registry.get(cmd) do
      nil ->
        {%{stdout: "", stderr: "bash: #{cmd}: command not found\n", exit_code: 127}, bash}

      module ->
        module.execute(bash, args, stdin)
    end
  end
end
