defmodule JustBash.Interpreter.Expansion do
  @moduledoc """
  Handles shell expansion: variables, command substitution, arithmetic.

  Delegates to specialized submodules:
  - `Parameter` - Parameter expansion operations (${VAR:-default}, etc.)
  - `Glob` - Glob expansion and pattern matching
  - `Brace` - Brace expansion ({a,b,c}, {1..10})
  """

  alias JustBash.Arithmetic
  alias JustBash.AST
  alias JustBash.Interpreter.Executor
  alias JustBash.Interpreter.Expansion.Brace
  alias JustBash.Interpreter.Expansion.Glob
  alias JustBash.Interpreter.Expansion.Parameter

  defmodule UnsetVariableError do
    @moduledoc "Raised when accessing an unset variable with set -u"
    defexception [:variable]

    @impl true
    def message(%{variable: var}), do: "#{var}: unbound variable"
  end

  @typedoc "Pending variable assignments from expansions like ${VAR:=default} or $((x++))"
  @type pending_assignments :: [{String.t(), String.t()}]

  @doc """
  Expand word parts into a string, handling all substitution types.
  Returns the expanded string and any pending variable assignments.

  ## Examples

      iex> expand_word_parts(bash, [%AST.Literal{value: "hello"}])
      {"hello", []}

      iex> expand_word_parts(bash, [%AST.ParameterExpansion{parameter: "x", operation: %AST.AssignDefault{...}}])
      {"default", [{"x", "default"}]}
  """
  @spec expand_word_parts(JustBash.t(), [AST.word_part()]) :: {String.t(), pending_assignments()}
  def expand_word_parts(bash, parts) do
    # Expand parts sequentially, applying any pending assignments between parts
    # This ensures side effects like $((x++)) are visible to subsequent parts
    {result, _final_bash, assignments} =
      Enum.reduce(parts, {"", bash, []}, fn part, {acc, current_bash, assigns} ->
        {expanded, new_assigns} = expand_part(current_bash, part)
        # Apply new assignments to bash so subsequent parts see them
        new_bash = apply_assignments_to_bash(current_bash, new_assigns)
        {acc <> expanded, new_bash, assigns ++ new_assigns}
      end)

    {result, assignments}
  end

  @doc """
  Expand word parts into a string, discarding pending assignments.
  Use this when you don't need to track variable assignments (e.g., in pattern matching).
  """
  @spec expand_word_parts_simple(JustBash.t(), [AST.word_part()]) :: String.t()
  def expand_word_parts_simple(bash, parts) do
    {result, _assignments} = expand_word_parts(bash, parts)
    result
  end

  # Apply assignments to bash env (for internal use during expansion)
  defp apply_assignments_to_bash(bash, []), do: bash

  defp apply_assignments_to_bash(bash, assignments) do
    Enum.reduce(assignments, bash, fn {name, value}, acc ->
      %{acc | env: Map.put(acc.env, name, value)}
    end)
  end

  @doc """
  Expand word parts with brace and glob expansion, returning a list of strings.
  Used for command arguments where globs should expand to multiple files.

  Expansion order: brace -> parameter/command -> word splitting (IFS) -> glob
  """
  @spec expand_word_with_glob(JustBash.t(), [AST.word_part()]) ::
          {[String.t()], pending_assignments()}
  def expand_word_with_glob(bash, parts) do
    has_unquoted_glob = has_unquoted_glob?(parts)
    needs_ifs_split = has_unquoted_expansion?(parts)
    ifs = Map.get(bash.env, "IFS", " \t\n")

    {expanded_words, assignments} = Brace.expand_with_brace(bash, parts)

    # Apply IFS word splitting if there are unquoted variable/command substitutions
    split_words =
      if needs_ifs_split and ifs != "" do
        Enum.flat_map(expanded_words, &Glob.split_on_ifs(&1, ifs))
      else
        expanded_words
      end

    final_words =
      Enum.flat_map(split_words, fn word_str ->
        if has_unquoted_glob and Glob.has_glob_chars?(word_str) do
          Glob.expand(bash, word_str)
        else
          [word_str]
        end
      end)

    {final_words, assignments}
  end

  # Check if parts contain unquoted variable or command substitution
  # that should trigger IFS word splitting
  defp has_unquoted_expansion?(parts) do
    Enum.any?(parts, fn
      %AST.ParameterExpansion{} -> true
      %AST.CommandSubstitution{} -> true
      %AST.ArithmeticExpansion{} -> true
      _ -> false
    end)
  end

  defp has_unquoted_glob?(parts) do
    Enum.any?(parts, fn
      %AST.Glob{} ->
        true

      %AST.BraceExpansion{items: items} ->
        Enum.any?(items, fn
          {:word, word} -> has_unquoted_glob?(word.parts)
          _ -> false
        end)

      _ ->
        false
    end)
  end

  # All expand_part functions return {expanded_string, pending_assignments}

  defp expand_part(_bash, part) when is_binary(part), do: {part, []}

  defp expand_part(_bash, %AST.Literal{value: value}), do: {value, []}

  defp expand_part(_bash, %AST.SingleQuoted{value: value}), do: {value, []}

  defp expand_part(_bash, %AST.Escaped{value: value}), do: {value, []}

  defp expand_part(bash, %AST.DoubleQuoted{parts: parts}) do
    expand_word_parts(bash, parts)
  end

  defp expand_part(bash, %AST.ParameterExpansion{} = param) do
    Parameter.expand(bash, param)
  end

  defp expand_part(bash, %AST.CommandSubstitution{body: body}) do
    {execute_command_substitution(bash, body), []}
  end

  defp expand_part(bash, %AST.ArithmeticExpression{} = expr) do
    execute_arithmetic_expansion(bash, expr)
  end

  defp expand_part(bash, %AST.ArithmeticExpansion{expression: expr}) do
    execute_arithmetic_expansion(bash, expr)
  end

  defp expand_part(bash, %{parts: parts}) do
    expand_word_parts(bash, parts)
  end

  defp expand_part(_bash, %AST.Glob{pattern: pattern}), do: {pattern, []}

  defp expand_part(bash, %AST.TildeExpansion{user: nil}) do
    {Map.get(bash.env, "HOME", "~"), []}
  end

  defp expand_part(_bash, %AST.TildeExpansion{user: user}), do: {"~#{user}", []}

  defp expand_part(_bash, _), do: {"", []}

  defp execute_arithmetic_expansion(bash, %AST.ArithmeticExpression{expression: inner_expr}) do
    case Arithmetic.evaluate(inner_expr, bash.env) do
      {:ok, value, new_env} ->
        assignments = collect_arithmetic_env_changes(bash.env, new_env)
        {to_string(value), assignments}

      {:error, :division_by_zero, _env} ->
        raise ArithmeticError, message: "division by 0"
    end
  end

  defp execute_arithmetic_expansion(bash, expr) do
    case Arithmetic.evaluate(expr, bash.env) do
      {:ok, value, new_env} ->
        assignments = collect_arithmetic_env_changes(bash.env, new_env)
        {to_string(value), assignments}

      {:error, :division_by_zero, _env} ->
        raise ArithmeticError, message: "division by 0"
    end
  end

  # Collect any env changes from arithmetic evaluation as pending assignments
  defp collect_arithmetic_env_changes(old_env, new_env) do
    Enum.reduce(new_env, [], fn {key, value}, acc ->
      if Map.get(old_env, key) != value do
        [{key, value} | acc]
      else
        acc
      end
    end)
  end

  defp execute_command_substitution(bash, %AST.Script{} = script) do
    {result, _bash} = Executor.execute_script(bash, script)
    String.trim_trailing(result.stdout, "\n")
  end

  @doc """
  Expand a parameter with optional operations.
  Returns {expanded_value, pending_assignments}.

  Delegates to `JustBash.Interpreter.Expansion.Parameter`.
  """
  @spec expand_parameter(JustBash.t(), AST.ParameterExpansion.t()) ::
          {String.t(), pending_assignments()}
  defdelegate expand_parameter(bash, param), to: Parameter, as: :expand

  @doc """
  Expand redirection target.
  """
  @spec expand_redirect_target(JustBash.t(), AST.Word.t() | String.t() | any()) :: String.t()
  def expand_redirect_target(bash, %AST.Word{parts: parts}) do
    expand_word_parts_simple(bash, parts)
  end

  def expand_redirect_target(_bash, target) when is_binary(target), do: target
  def expand_redirect_target(_bash, _), do: ""

  @doc """
  Expand words for a for-loop, applying IFS splitting to unquoted expansions.

  In bash, IFS splitting only happens on unquoted variable/command substitution results.
  Quoted strings (single or double) are not split.
  Brace expansion produces multiple words directly.
  """
  @spec expand_for_loop_words(JustBash.t(), [AST.Word.t()]) :: [String.t()]
  def expand_for_loop_words(bash, words) do
    ifs = Map.get(bash.env, "IFS", " \t\n")

    Enum.flat_map(words, fn word ->
      expand_for_loop_word(bash, word.parts, ifs)
    end)
  end

  defp expand_for_loop_word(bash, parts, ifs) do
    if Brace.has_brace_expansion?(parts) do
      {words, _assigns} = expand_word_with_glob(bash, parts)
      words
    else
      expand_for_loop_word_no_brace(bash, parts, ifs)
    end
  end

  defp expand_for_loop_word_no_brace(bash, parts, ifs) do
    # Special case: if the word is just "$@", expand to multiple words
    case is_quoted_at_expansion?(parts) do
      {:ok, :quoted_at} ->
        expand_quoted_at_to_words(bash)

      :not_at ->
        has_unquoted_glob = has_unquoted_glob?(parts)
        expanded_segments = Enum.map(parts, &expand_for_loop_part(bash, &1, ifs))
        needs_ifs_split = Enum.any?(expanded_segments, fn {_, split?} -> split? end)
        combined = Enum.map_join(expanded_segments, "", fn {str, _} -> str end)
        results = maybe_split_on_ifs(combined, ifs, needs_ifs_split)
        maybe_expand_globs(bash, results, has_unquoted_glob)
    end
  end

  defp is_quoted_at_expansion?([
         %AST.DoubleQuoted{parts: [%AST.ParameterExpansion{parameter: "@", operation: nil}]}
       ]) do
    {:ok, :quoted_at}
  end

  defp is_quoted_at_expansion?(_parts), do: :not_at

  defp expand_quoted_at_to_words(bash) do
    bash.env
    |> Enum.filter(fn {key, _} ->
      case Integer.parse(key) do
        {n, ""} when n >= 1 -> true
        _ -> false
      end
    end)
    |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end)
    |> Enum.map(fn {_, value} -> value end)
  end

  defp maybe_split_on_ifs(combined, ifs, true = _needs_split) when ifs != "" do
    Glob.split_on_ifs(combined, ifs)
  end

  defp maybe_split_on_ifs(combined, _ifs, _needs_split), do: [combined]

  defp maybe_expand_globs(_bash, results, false = _has_glob), do: results

  defp maybe_expand_globs(bash, results, true = _has_glob) do
    Enum.flat_map(results, &expand_if_glob(bash, &1))
  end

  defp expand_if_glob(bash, word_str) do
    if Glob.has_glob_chars?(word_str), do: Glob.expand(bash, word_str), else: [word_str]
  end

  defp expand_for_loop_part(_bash, %AST.Literal{value: value}, _ifs) do
    {value, false}
  end

  defp expand_for_loop_part(_bash, %AST.SingleQuoted{value: value}, _ifs) do
    {value, false}
  end

  defp expand_for_loop_part(bash, %AST.DoubleQuoted{parts: parts}, _ifs) do
    {expanded, _assigns} = expand_word_parts(bash, parts)
    {expanded, false}
  end

  defp expand_for_loop_part(_bash, %AST.Escaped{value: value}, _ifs) do
    {value, false}
  end

  defp expand_for_loop_part(bash, %AST.ParameterExpansion{} = param, _ifs) do
    {expanded, _assigns} = Parameter.expand(bash, param)
    {expanded, true}
  end

  defp expand_for_loop_part(bash, %AST.CommandSubstitution{body: body}, _ifs) do
    {execute_command_substitution(bash, body), true}
  end

  defp expand_for_loop_part(bash, %AST.ArithmeticExpansion{expression: expr}, _ifs) do
    {expanded, _assigns} = execute_arithmetic_expansion(bash, expr)
    {expanded, true}
  end

  defp expand_for_loop_part(_bash, %AST.Glob{pattern: pattern}, _ifs) do
    {pattern, false}
  end

  defp expand_for_loop_part(bash, %AST.TildeExpansion{user: nil}, _ifs) do
    {Map.get(bash.env, "HOME", "~"), false}
  end

  defp expand_for_loop_part(_bash, %AST.TildeExpansion{user: user}, _ifs) do
    {"~#{user}", false}
  end

  defp expand_for_loop_part(_bash, _, _ifs) do
    {"", false}
  end
end
