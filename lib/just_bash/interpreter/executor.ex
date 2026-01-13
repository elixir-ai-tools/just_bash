defmodule JustBash.Interpreter.Executor do
  @moduledoc """
  Executes parsed bash AST nodes.
  """

  alias JustBash.AST
  alias JustBash.Commands.Registry
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Interpreter.Expansion

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
    {final_bash, stdout, stderr, exit_code, _halted} =
      Enum.reduce_while(statements, {bash, "", "", 0, false}, fn stmt, {b, out, err, _code, _} ->
        {result, new_bash} = execute_statement(b, stmt)
        new_env = Map.put(new_bash.env, "?", to_string(result.exit_code))
        new_bash = %{new_bash | last_exit_code: result.exit_code, env: new_env}
        acc = {new_bash, out <> result.stdout, err <> result.stderr, result.exit_code, false}

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
      stdout: stdout,
      stderr: stderr,
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
    execute_pipelines(bash, pipelines, operators, 0, "", "", nil)
  end

  def execute_statement(bash, %AST.Group{body: body}) do
    execute_body_with_bash(bash, body)
  end

  defp execute_pipelines(bash, [], _operators, exit_code, stdout, stderr, _prev_op) do
    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, bash}
  end

  defp execute_pipelines(bash, [pipeline | rest], operators, prev_exit, stdout, stderr, prev_op) do
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

      execute_pipelines(
        new_bash,
        rest,
        next_operators,
        result.exit_code,
        stdout <> result.stdout,
        stderr <> result.stderr,
        next_op
      )
    else
      execute_pipelines(bash, rest, next_operators, prev_exit, stdout, stderr, next_op)
    end
  end

  defp advance_operators([op | rest]), do: {op, rest}
  defp advance_operators([]), do: {nil, []}

  @doc """
  Execute a pipeline (commands connected by |).
  """
  @spec execute_pipeline(JustBash.t(), AST.Pipeline.t()) :: {result(), JustBash.t()}
  def execute_pipeline(bash, %AST.Pipeline{commands: commands, negated: negated}) do
    # Track all exit codes for pipefail
    {final_result, final_bash, exit_codes} =
      Enum.reduce(commands, {%{stdout: "", stderr: "", exit_code: 0}, bash, []}, fn cmd,
                                                                                    {prev_result,
                                                                                     current_bash,
                                                                                     codes} ->
        {result, new_bash} = execute_command(current_bash, cmd, prev_result.stdout)
        {result, new_bash, codes ++ [result.exit_code]}
      end)

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
    try do
      temp_bash = execute_assignments(bash, assignments)
      cmd_name = Expansion.expand_word_parts(temp_bash, name.parts)

      # Apply any assignments from ${VAR:=default} expansions
      temp_bash = apply_expansion_assignments(temp_bash)

      expanded_args =
        Enum.flat_map(args, fn arg -> Expansion.expand_word_with_glob(temp_bash, arg.parts) end)

      # Apply assignments from arg expansion as well
      temp_bash = apply_expansion_assignments(temp_bash)

      # Extract heredoc content as stdin if present
      {heredoc_stdin, non_heredoc_redirs} = extract_heredoc_stdin(temp_bash, redirs)
      effective_stdin = heredoc_stdin || stdin

      {result, exec_bash} =
        case Map.get(temp_bash.functions, cmd_name) do
          nil ->
            execute_builtin(temp_bash, cmd_name, expanded_args, effective_stdin)

          func_body ->
            execute_function(temp_bash, func_body, expanded_args)
        end

      {result, exec_bash} = apply_redirections(result, exec_bash, non_heredoc_redirs)
      {result, exec_bash}
    rescue
      e in Expansion.UnsetVariableError ->
        {%{stdout: "", stderr: "bash: #{Exception.message(e)}\n", exit_code: 1}, bash}
    end
  end

  def execute_command(bash, %AST.If{clauses: clauses, else_body: else_body}, _stdin),
    do: execute_if(bash, clauses, else_body)

  def execute_command(bash, %AST.For{variable: variable, words: words, body: body}, _stdin),
    do: execute_for(bash, variable, words, body)

  def execute_command(bash, %AST.While{condition: condition, body: body}, _stdin),
    do: execute_while(bash, condition, body, false)

  def execute_command(bash, %AST.Until{condition: condition, body: body}, _stdin),
    do: execute_while(bash, condition, body, true)

  def execute_command(bash, %AST.Case{word: word, items: items}, _stdin) do
    value = Expansion.expand_word_parts(bash, word.parts)
    execute_case(bash, value, items)
  end

  def execute_command(bash, %AST.Subshell{body: body}, _stdin) do
    {result, _subshell_bash} = execute_body(bash, body)
    {result, bash}
  end

  def execute_command(bash, %AST.Group{body: body}, _stdin) do
    execute_body_with_bash(bash, body)
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
    result = evaluate_conditional(bash, expr)
    exit_code = if result, do: 0, else: 1
    {%{stdout: "", stderr: "", exit_code: exit_code}, bash}
  end

  def execute_command(bash, _command, _stdin),
    do: {%{stdout: "", stderr: "", exit_code: 0}, bash}

  defp evaluate_conditional(bash, %AST.CondWord{word: word}) do
    value = Expansion.expand_word_parts(bash, word.parts)
    value != ""
  end

  defp evaluate_conditional(bash, %AST.CondNot{operand: operand}) do
    not evaluate_conditional(bash, operand)
  end

  defp evaluate_conditional(bash, %AST.CondAnd{left: left, right: right}) do
    evaluate_conditional(bash, left) and evaluate_conditional(bash, right)
  end

  defp evaluate_conditional(bash, %AST.CondOr{left: left, right: right}) do
    evaluate_conditional(bash, left) or evaluate_conditional(bash, right)
  end

  defp evaluate_conditional(bash, %AST.CondGroup{expression: expr}) do
    evaluate_conditional(bash, expr)
  end

  defp evaluate_conditional(bash, %AST.CondUnary{operator: op, operand: word}) do
    path = Expansion.expand_word_parts(bash, word.parts)
    resolved = JustBash.Fs.InMemoryFs.resolve_path(bash.cwd, path)
    evaluate_unary_conditional(bash, op, path, resolved)
  end

  defp evaluate_conditional(bash, %AST.CondBinary{
         operator: op,
         left: left_word,
         right: right_word
       }) do
    left = Expansion.expand_word_parts(bash, left_word.parts)
    right = Expansion.expand_word_parts(bash, right_word.parts)
    evaluate_binary_conditional(bash, op, left, right)
  end

  defp evaluate_unary_conditional(bash, op, path, resolved) do
    evaluate_unary_by_type(unary_op_type(op), bash, path, resolved)
  end

  defp evaluate_unary_by_type(:file_exists, bash, _path, resolved),
    do: file_exists?(bash, resolved)

  defp evaluate_unary_by_type(:regular_file, bash, _path, resolved),
    do: regular_file?(bash, resolved)

  defp evaluate_unary_by_type(:directory, bash, _path, resolved),
    do: directory?(bash, resolved)

  defp evaluate_unary_by_type(:file_size, bash, _path, resolved),
    do: file_size_gt_zero?(bash, resolved)

  defp evaluate_unary_by_type(:string_empty, _bash, path, _resolved),
    do: path == ""

  defp evaluate_unary_by_type(:string_non_empty, _bash, path, _resolved),
    do: path != ""

  defp evaluate_unary_by_type(:symlink, bash, _path, resolved),
    do: symlink?(bash, resolved)

  defp evaluate_unary_by_type(:always_false, _bash, _path, _resolved),
    do: false

  defp evaluate_unary_by_type(:var_set, bash, path, _resolved),
    do: Map.has_key?(bash.env, path)

  defp unary_op_type(:"-e"), do: :file_exists
  defp unary_op_type(:"-a"), do: :file_exists
  defp unary_op_type(:"-f"), do: :regular_file
  defp unary_op_type(:"-d"), do: :directory
  defp unary_op_type(:"-r"), do: :file_exists
  defp unary_op_type(:"-w"), do: :file_exists
  defp unary_op_type(:"-x"), do: :file_exists
  defp unary_op_type(:"-s"), do: :file_size
  defp unary_op_type(:"-z"), do: :string_empty
  defp unary_op_type(:"-n"), do: :string_non_empty
  defp unary_op_type(:"-L"), do: :symlink
  defp unary_op_type(:"-h"), do: :symlink
  defp unary_op_type(:"-O"), do: :file_exists
  defp unary_op_type(:"-G"), do: :file_exists
  defp unary_op_type(:"-N"), do: :file_exists
  defp unary_op_type(:"-v"), do: :var_set
  defp unary_op_type(:"-b"), do: :always_false
  defp unary_op_type(:"-c"), do: :always_false
  defp unary_op_type(:"-p"), do: :always_false
  defp unary_op_type(:"-S"), do: :always_false
  defp unary_op_type(:"-t"), do: :always_false
  defp unary_op_type(:"-g"), do: :always_false
  defp unary_op_type(:"-u"), do: :always_false
  defp unary_op_type(:"-k"), do: :always_false
  defp unary_op_type(_), do: :always_false

  defp evaluate_binary_conditional(bash, op, left, right) do
    case binary_op_type(op) do
      :integer_comparison -> evaluate_integer_comparison(op, left, right)
      :file_comparison -> evaluate_file_comparison(bash, op, left, right)
      :string_comparison -> evaluate_string_comparison(op, left, right)
    end
  end

  defp binary_op_type(op) when op in [:"-eq", :"-ne", :"-lt", :"-le", :"-gt", :"-ge"],
    do: :integer_comparison

  defp binary_op_type(op) when op in [:"-nt", :"-ot", :"-ef"], do: :file_comparison
  defp binary_op_type(_), do: :string_comparison

  defp evaluate_integer_comparison(:"-eq", left, right),
    do: parse_int(left) == parse_int(right)

  defp evaluate_integer_comparison(:"-ne", left, right),
    do: parse_int(left) != parse_int(right)

  defp evaluate_integer_comparison(:"-lt", left, right),
    do: parse_int(left) < parse_int(right)

  defp evaluate_integer_comparison(:"-le", left, right),
    do: parse_int(left) <= parse_int(right)

  defp evaluate_integer_comparison(:"-gt", left, right),
    do: parse_int(left) > parse_int(right)

  defp evaluate_integer_comparison(:"-ge", left, right),
    do: parse_int(left) >= parse_int(right)

  defp evaluate_file_comparison(bash, :"-nt", left, right), do: file_newer?(bash, left, right)
  defp evaluate_file_comparison(bash, :"-ot", left, right), do: file_newer?(bash, right, left)
  defp evaluate_file_comparison(bash, :"-ef", left, right), do: same_file?(bash, left, right)

  defp evaluate_string_comparison(:=, left, right), do: left == right
  defp evaluate_string_comparison(:==, left, right), do: pattern_match?(left, right)
  defp evaluate_string_comparison(:!=, left, right), do: not pattern_match?(left, right)
  defp evaluate_string_comparison(:=~, left, right), do: regex_match?(left, right)
  defp evaluate_string_comparison(:<, left, right), do: left < right
  defp evaluate_string_comparison(:>, left, right), do: left > right
  defp evaluate_string_comparison(_, _left, _right), do: false

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp pattern_match?(str, pattern) do
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("^" <> regex_pattern <> "$") do
      {:ok, regex} -> Regex.match?(regex, str)
      {:error, _} -> str == pattern
    end
  end

  defp regex_match?(str, pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, str)
      {:error, _} -> false
    end
  end

  defp file_exists?(bash, path) do
    case JustBash.Fs.InMemoryFs.stat(bash.fs, path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp regular_file?(bash, path) do
    case JustBash.Fs.InMemoryFs.stat(bash.fs, path) do
      {:ok, stat} -> stat.is_file
      {:error, _} -> false
    end
  end

  defp directory?(bash, path) do
    case JustBash.Fs.InMemoryFs.stat(bash.fs, path) do
      {:ok, stat} -> stat.is_directory
      {:error, _} -> false
    end
  end

  defp file_size_gt_zero?(bash, path) do
    case JustBash.Fs.InMemoryFs.stat(bash.fs, path) do
      {:ok, stat} -> stat.size > 0
      {:error, _} -> false
    end
  end

  defp symlink?(bash, path) do
    case JustBash.Fs.InMemoryFs.lstat(bash.fs, path) do
      {:ok, stat} -> stat.is_symlink
      {:error, _} -> false
    end
  end

  defp file_newer?(bash, path1, path2) do
    with {:ok, stat1} <- JustBash.Fs.InMemoryFs.stat(bash.fs, path1),
         {:ok, stat2} <- JustBash.Fs.InMemoryFs.stat(bash.fs, path2) do
      stat1.mtime > stat2.mtime
    else
      _ -> false
    end
  end

  defp same_file?(bash, path1, path2) do
    resolved1 = JustBash.Fs.InMemoryFs.resolve_path(bash.cwd, path1)
    resolved2 = JustBash.Fs.InMemoryFs.resolve_path(bash.cwd, path2)
    resolved1 == resolved2
  end

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

      {%{
         body_result
         | stdout: cond_result.stdout <> body_result.stdout,
           stderr: cond_result.stderr <> body_result.stderr
       }, new_bash}
    else
      {else_result, new_bash} = execute_if(cond_bash, rest, else_body)

      {%{
         else_result
         | stdout: cond_result.stdout <> else_result.stdout,
           stderr: cond_result.stderr <> else_result.stderr
       }, new_bash}
    end
  end

  defp execute_for(bash, variable, words, body) do
    expanded_words = Expansion.expand_for_loop_words(bash, words)
    execute_for_loop(bash, variable, expanded_words, body, "", "", 0)
  end

  defp execute_for_loop(bash, _variable, [], _body, stdout, stderr, exit_code) do
    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, bash}
  end

  defp execute_for_loop(bash, variable, [value | rest], body, stdout, stderr, _exit_code) do
    new_bash = %{bash | env: Map.put(bash.env, variable, value)}
    {result, body_bash} = execute_body(new_bash, body)

    execute_for_loop(
      body_bash,
      variable,
      rest,
      body,
      stdout <> result.stdout,
      stderr <> result.stderr,
      result.exit_code
    )
  end

  defp execute_while(bash, condition, body, is_until) do
    execute_while_loop(bash, condition, body, is_until, "", "", 0, 0)
  end

  defp execute_while_loop(bash, _cond, _body, _is_until, stdout, stderr, exit_code, iterations)
       when iterations >= 1000 do
    {%{
       stdout: stdout,
       stderr: stderr <> "loop: iteration limit exceeded\n",
       exit_code: exit_code
     }, bash}
  end

  defp execute_while_loop(bash, condition, body, is_until, stdout, stderr, exit_code, iterations) do
    {cond_result, cond_bash} = execute_body(bash, condition)

    should_continue =
      if is_until do
        cond_result.exit_code != 0
      else
        cond_result.exit_code == 0
      end

    new_stdout = stdout <> cond_result.stdout
    new_stderr = stderr <> cond_result.stderr

    if should_continue do
      {body_result, body_bash} = execute_body(cond_bash, body)

      execute_while_loop(
        body_bash,
        condition,
        body,
        is_until,
        new_stdout <> body_result.stdout,
        new_stderr <> body_result.stderr,
        body_result.exit_code,
        iterations + 1
      )
    else
      {%{stdout: new_stdout, stderr: new_stderr, exit_code: exit_code}, cond_bash}
    end
  end

  defp execute_case(bash, _value, []) do
    {%{stdout: "", stderr: "", exit_code: 0}, bash}
  end

  defp execute_case(bash, value, [%AST.CaseItem{patterns: patterns, body: body} | rest]) do
    matches? =
      Enum.any?(patterns, fn pattern ->
        pattern_str = Expansion.expand_word_parts(bash, pattern.parts)
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
    {final_bash, stdout, stderr, exit_code} =
      Enum.reduce(statements, {bash, "", "", 0}, fn stmt, {b, out, err, _code} ->
        {result, new_bash} = execute_statement(b, stmt)
        {new_bash, out <> result.stdout, err <> result.stderr, result.exit_code}
      end)

    {%{stdout: stdout, stderr: stderr, exit_code: exit_code, env: final_bash.env}, final_bash}
  end

  defp execute_body_with_bash(bash, statements) do
    {result, new_bash} = execute_body(bash, statements)
    {%{stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code}, new_bash}
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
    Enum.reduce(assignments, bash, fn %AST.Assignment{name: name, value: value}, acc ->
      expanded_value =
        case value do
          nil -> ""
          %AST.Word{parts: parts} -> Expansion.expand_word_parts(acc, parts)
          _ -> ""
        end

      %{acc | env: Map.put(acc.env, name, expanded_value)}
    end)
  end

  defp apply_expansion_assignments(bash) do
    case Expansion.get_pending_assignments() do
      [] ->
        bash

      assignments ->
        Enum.reduce(assignments, bash, fn {name, value}, acc ->
          %{acc | env: Map.put(acc.env, name, value)}
        end)
    end
  end

  defp execute_builtin(bash, cmd, args, stdin) do
    case Registry.get(cmd) do
      nil ->
        {%{stdout: "", stderr: "bash: #{cmd}: command not found\n", exit_code: 127}, bash}

      module ->
        module.execute(bash, args, stdin)
    end
  end

  defp extract_heredoc_stdin(bash, redirections) do
    {heredocs, others} =
      Enum.split_with(redirections, fn redir ->
        match?(%AST.Redirection{operator: op} when op in [:"<<", :"<<-"], redir)
      end)

    heredoc_content = extract_heredoc_content(bash, heredocs)
    {heredoc_content, others}
  end

  defp extract_heredoc_content(bash, [
         %AST.Redirection{target: %AST.HereDoc{content: content}} | _
       ])
       when not is_nil(content) do
    Expansion.expand_word_parts(bash, content.parts)
  end

  defp extract_heredoc_content(_bash, [%AST.Redirection{target: %AST.HereDoc{}} | _]) do
    ""
  end

  defp extract_heredoc_content(_bash, _heredocs) do
    nil
  end

  defp apply_redirections(result, bash, []) do
    {result, bash}
  end

  defp apply_redirections(result, bash, [redir | rest]) do
    {result, bash} = apply_redirection(result, bash, redir)
    apply_redirections(result, bash, rest)
  end

  defp apply_redirection(result, bash, %AST.Redirection{
         fd: fd,
         operator: operator,
         target: target
       }) do
    target_path = Expansion.expand_redirect_target(bash, target)
    resolved = InMemoryFs.resolve_path(bash.cwd, target_path)
    redir_type = classify_redirection(fd, operator, target_path)
    apply_classified_redirection(redir_type, result, bash, resolved)
  end

  defp classify_redirection(_fd, _operator, "/dev/null"), do: :dev_null
  defp classify_redirection(2, :>, _target), do: :stderr_write
  defp classify_redirection(2, :">>", _target), do: :stderr_append
  defp classify_redirection(_fd, :>, _target), do: :stdout_write
  defp classify_redirection(_fd, :">>", _target), do: :stdout_append
  defp classify_redirection(1, :">&", "2"), do: :stdout_to_stderr
  defp classify_redirection(2, :">&", "1"), do: :stderr_to_stdout
  defp classify_redirection(_fd, :"&>", _target), do: :combined_write
  defp classify_redirection(_fd, _operator, _target), do: :noop

  defp apply_classified_redirection(:dev_null, result, bash, _resolved) do
    {%{result | stdout: ""}, bash}
  end

  defp apply_classified_redirection(:stderr_write, result, bash, resolved) do
    write_to_file(bash, resolved, result.stderr, result, :stderr)
  end

  defp apply_classified_redirection(:stderr_append, result, bash, resolved) do
    append_to_file(bash, resolved, result.stderr, result, :stderr)
  end

  defp apply_classified_redirection(:stdout_write, result, bash, resolved) do
    write_to_file(bash, resolved, result.stdout, result, :stdout)
  end

  defp apply_classified_redirection(:stdout_append, result, bash, resolved) do
    append_to_file(bash, resolved, result.stdout, result, :stdout)
  end

  defp apply_classified_redirection(:stdout_to_stderr, result, bash, _resolved) do
    {%{result | stderr: result.stderr <> result.stdout, stdout: ""}, bash}
  end

  defp apply_classified_redirection(:stderr_to_stdout, result, bash, _resolved) do
    {%{result | stdout: result.stdout <> result.stderr, stderr: ""}, bash}
  end

  defp apply_classified_redirection(:combined_write, result, bash, resolved) do
    combined = result.stdout <> result.stderr
    write_combined_to_file(bash, resolved, combined, result)
  end

  defp apply_classified_redirection(:noop, result, bash, _resolved) do
    {result, bash}
  end

  defp write_to_file(bash, path, content, result, stream) do
    case InMemoryFs.write_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        updated_result = clear_stream(result, stream)
        {updated_result, %{bash | fs: new_fs}}

      {:error, reason} ->
        error_msg = format_redirection_error(path, reason)
        {%{result | stderr: result.stderr <> error_msg, exit_code: 1}, bash}
    end
  end

  defp append_to_file(bash, path, content, result, stream) do
    current_content =
      case InMemoryFs.read_file(bash.fs, path) do
        {:ok, existing} -> existing
        {:error, _} -> ""
      end

    case InMemoryFs.write_file(bash.fs, path, current_content <> content) do
      {:ok, new_fs} ->
        updated_result = clear_stream(result, stream)
        {updated_result, %{bash | fs: new_fs}}

      {:error, reason} ->
        error_msg = format_redirection_error(path, reason)
        {%{result | stderr: result.stderr <> error_msg, exit_code: 1}, bash}
    end
  end

  defp write_combined_to_file(bash, path, content, result) do
    case InMemoryFs.write_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        {%{result | stdout: "", stderr: ""}, %{bash | fs: new_fs}}

      {:error, reason} ->
        error_msg = format_redirection_error(path, reason)
        {%{result | stderr: error_msg, exit_code: 1}, bash}
    end
  end

  defp clear_stream(result, :stdout), do: %{result | stdout: ""}
  defp clear_stream(result, :stderr), do: %{result | stderr: ""}

  defp format_redirection_error(path, :eisdir), do: "bash: #{path}: Is a directory\n"
end
