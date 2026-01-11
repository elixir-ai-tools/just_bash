defmodule JustBash.Interpreter.Executor do
  @moduledoc """
  Executes parsed bash AST nodes.
  """

  alias JustBash.AST
  alias JustBash.Commands.Registry
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Interpreter.Expansion

  @type result :: %{stdout: String.t(), stderr: String.t(), exit_code: non_neg_integer()}

  @doc """
  Execute a parsed script AST.
  Returns {result, updated_bash}.
  """
  @spec execute_script(JustBash.t(), AST.Script.t()) :: {result(), JustBash.t()}
  def execute_script(bash, %AST.Script{statements: statements}) do
    {final_bash, stdout, stderr, exit_code} =
      Enum.reduce(statements, {bash, "", "", 0}, fn stmt, {b, out, err, _code} ->
        {result, new_bash} = execute_statement(b, stmt)
        new_env = Map.put(new_bash.env, "?", to_string(result.exit_code))
        new_bash = %{new_bash | last_exit_code: result.exit_code, env: new_env}
        {new_bash, out <> result.stdout, err <> result.stderr, result.exit_code}
      end)

    result = %{
      stdout: stdout,
      stderr: stderr,
      exit_code: exit_code,
      env: final_bash.env
    }

    {result, final_bash}
  end

  @doc """
  Execute a statement (one or more pipelines with && or ||).
  """
  @spec execute_statement(JustBash.t(), AST.Statement.t()) :: {result(), JustBash.t()}
  def execute_statement(bash, %AST.Statement{pipelines: pipelines, operators: operators}) do
    execute_pipelines(bash, pipelines, operators, 0, "", "", nil)
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

    if should_run do
      {result, new_bash} = execute_pipeline(bash, pipeline)

      next_op =
        case operators do
          [op | _] -> op
          [] -> nil
        end

      next_operators =
        case operators do
          [_ | rest_ops] -> rest_ops
          [] -> []
        end

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
      next_op =
        case operators do
          [op | _] -> op
          [] -> nil
        end

      next_operators =
        case operators do
          [_ | rest_ops] -> rest_ops
          [] -> []
        end

      execute_pipelines(bash, rest, next_operators, prev_exit, stdout, stderr, next_op)
    end
  end

  @doc """
  Execute a pipeline (commands connected by |).
  """
  @spec execute_pipeline(JustBash.t(), AST.Pipeline.t()) :: {result(), JustBash.t()}
  def execute_pipeline(bash, %AST.Pipeline{commands: commands, negated: negated}) do
    {final_result, final_bash} =
      Enum.reduce(commands, {%{stdout: "", stderr: "", exit_code: 0}, bash}, fn cmd,
                                                                                {prev_result,
                                                                                 current_bash} ->
        {result, new_bash} = execute_command(current_bash, cmd, prev_result.stdout)
        {result, new_bash}
      end)

    exit_code =
      if negated do
        if final_result.exit_code == 0, do: 1, else: 0
      else
        final_result.exit_code
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
    temp_bash = execute_assignments(bash, assignments)
    cmd_name = Expansion.expand_word_parts(temp_bash, name.parts)

    expanded_args =
      Enum.map(args, fn arg -> Expansion.expand_word_parts(temp_bash, arg.parts) end)

    {result, exec_bash} =
      case Map.get(temp_bash.functions, cmd_name) do
        nil ->
          execute_builtin(temp_bash, cmd_name, expanded_args, stdin)

        func_body ->
          execute_function(temp_bash, func_body, expanded_args)
      end

    {result, exec_bash} = apply_redirections(result, exec_bash, redirs)

    {result, exec_bash}
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

  def execute_command(bash, _command, _stdin),
    do: {%{stdout: "", stderr: "", exit_code: 0}, bash}

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
    expanded_words =
      Enum.flat_map(words, fn word ->
        expanded = Expansion.expand_word_parts(bash, word.parts)
        String.split(expanded, ~r/\s+/, trim: true)
      end)

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

  defp execute_builtin(bash, cmd, args, stdin) do
    case Registry.get(cmd) do
      nil ->
        {%{stdout: "", stderr: "bash: #{cmd}: command not found\n", exit_code: 127}, bash}

      module ->
        module.execute(bash, args, stdin)
    end
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

    cond do
      target_path == "/dev/null" ->
        case fd do
          2 -> {%{result | stderr: ""}, bash}
          _ -> {%{result | stdout: ""}, bash}
        end

      fd == 2 and operator == :> ->
        {:ok, new_fs} = InMemoryFs.write_file(bash.fs, resolved, result.stderr)
        {%{result | stderr: ""}, %{bash | fs: new_fs}}

      fd == 2 and operator == :">>" ->
        current_content =
          case InMemoryFs.read_file(bash.fs, resolved) do
            {:ok, content} -> content
            {:error, _} -> ""
          end

        {:ok, new_fs} = InMemoryFs.write_file(bash.fs, resolved, current_content <> result.stderr)
        {%{result | stderr: ""}, %{bash | fs: new_fs}}

      operator == :> ->
        {:ok, new_fs} = InMemoryFs.write_file(bash.fs, resolved, result.stdout)
        {%{result | stdout: ""}, %{bash | fs: new_fs}}

      operator == :">>" ->
        current_content =
          case InMemoryFs.read_file(bash.fs, resolved) do
            {:ok, content} -> content
            {:error, _} -> ""
          end

        {:ok, new_fs} = InMemoryFs.write_file(bash.fs, resolved, current_content <> result.stdout)
        {%{result | stdout: ""}, %{bash | fs: new_fs}}

      fd == 1 and operator == :">&" and target_path == "2" ->
        {%{result | stderr: result.stderr <> result.stdout, stdout: ""}, bash}

      fd == 2 and operator == :">&" and target_path == "1" ->
        {%{result | stdout: result.stdout <> result.stderr, stderr: ""}, bash}

      operator == :"&>" ->
        combined = result.stdout <> result.stderr
        {:ok, new_fs} = InMemoryFs.write_file(bash.fs, resolved, combined)
        {%{result | stdout: "", stderr: ""}, %{bash | fs: new_fs}}

      true ->
        {result, bash}
    end
  end
end
