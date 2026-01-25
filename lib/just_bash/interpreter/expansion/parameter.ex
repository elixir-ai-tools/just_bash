defmodule JustBash.Interpreter.Expansion.Parameter do
  @moduledoc """
  Parameter expansion operations for bash variables.

  Handles all forms of parameter expansion including:
  - Default values: ${VAR:-default}, ${VAR:=default}
  - Alternative values: ${VAR:+alt}
  - Error on unset: ${VAR:?error}
  - Length: ${#VAR}
  - Substring: ${VAR:offset:length}
  - Pattern removal: ${VAR#pattern}, ${VAR##pattern}, ${VAR%pattern}, ${VAR%%pattern}
  - Pattern replacement: ${VAR/pattern/replacement}, ${VAR//pattern/replacement}
  - Case modification: ${VAR^}, ${VAR^^}, ${VAR,}, ${VAR,,}
  - Indirection: ${!VAR}
  - Arrays: ${arr[@]}, ${arr[*]}, ${arr[n]}, ${#arr[@]}
  """

  alias JustBash.Arithmetic
  alias JustBash.AST
  alias JustBash.Interpreter.Expansion

  @typedoc "Pending variable assignments from expansions like ${VAR:=default}"
  @type pending_assignments :: Expansion.pending_assignments()

  @doc """
  Expand a parameter with optional operations.
  Returns {expanded_value, pending_assignments}.
  """
  @spec expand(JustBash.t(), AST.ParameterExpansion.t()) :: {String.t(), pending_assignments()}
  def expand(bash, %AST.ParameterExpansion{parameter: name, operation: nil}) do
    result =
      case parse_array_subscript(name) do
        {:array_all, arr_name} ->
          expand_array_all(bash, arr_name)

        {:array_index, arr_name, index} ->
          expand_array_index(bash, arr_name, index)

        :not_array ->
          expand_simple_variable(bash, name)
      end

    {result, []}
  end

  def expand(bash, %AST.ParameterExpansion{parameter: name, operation: operation}) do
    value = Map.get(bash.env, name)
    expand_with_operation(bash, name, value, operation)
  end

  # Simple variable expansion (no operation)
  defp expand_simple_variable(bash, name) do
    case Map.fetch(bash.env, name) do
      {:ok, value} ->
        value

      :error ->
        if bash.shell_opts.nounset and not special_variable?(name) do
          raise Expansion.UnsetVariableError, variable: name
        else
          ""
        end
    end
  end

  # Array subscript parsing

  defp parse_array_subscript(name) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_]*)\[(.+)\]$/, name) do
      [_, arr_name, "@"] -> {:array_all, arr_name}
      [_, arr_name, "*"] -> {:array_all, arr_name}
      [_, arr_name, index] -> {:array_index, arr_name, index}
      nil -> :not_array
    end
  end

  @doc false
  def expand_array_all(bash, arr_name) do
    bash.env
    |> Enum.filter(fn {key, _} ->
      case Regex.run(~r/^#{Regex.escape(arr_name)}\[(\d+)\]$/, key) do
        [_, _idx] -> true
        nil -> false
      end
    end)
    |> Enum.map(fn {key, value} ->
      [_, idx] = Regex.run(~r/\[(\d+)\]$/, key)
      {String.to_integer(idx), value}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(" ", &elem(&1, 1))
  end

  @doc false
  def expand_array_index(bash, arr_name, index_str) do
    index =
      case Integer.parse(index_str) do
        {n, ""} ->
          n

        _ ->
          expr = Arithmetic.parse(index_str)

          case Arithmetic.evaluate(expr, bash.env) do
            {:ok, n, _env} -> n
            {:error, :division_by_zero, _env} -> raise ArithmeticError, message: "division by 0"
          end
      end

    key = "#{arr_name}[#{index}]"
    Map.get(bash.env, key, "")
  end

  # Special variables that are always considered "set" for nounset purposes
  defp special_variable?(name) when name in ["?", "$", "!", "#", "*", "@", "-", "0"], do: true
  defp special_variable?(name), do: String.match?(name, ~r/^[0-9]+$/)

  # Operation expansions - all return {expanded_value, pending_assignments}

  defp expand_with_operation(bash, _name, value, %AST.DefaultValue{
         word: word,
         check_empty: check_empty
       }) do
    {default_val, assigns} =
      if word, do: Expansion.expand_word_parts(bash, word.parts), else: {"", []}

    should_use_default =
      if check_empty do
        value == nil or value == ""
      else
        value == nil
      end

    if should_use_default, do: {default_val, assigns}, else: {value || "", []}
  end

  defp expand_with_operation(bash, name, value, %AST.AssignDefault{
         word: word,
         check_empty: check_empty
       }) do
    {default_val, assigns} =
      if word, do: Expansion.expand_word_parts(bash, word.parts), else: {"", []}

    should_assign =
      if check_empty do
        value == nil or value == ""
      else
        value == nil
      end

    if should_assign do
      {default_val, [{name, default_val} | assigns]}
    else
      {value || "", []}
    end
  end

  defp expand_with_operation(bash, _name, value, %AST.UseAlternative{
         word: word,
         check_empty: check_empty
       }) do
    {alt_val, assigns} =
      if word, do: Expansion.expand_word_parts(bash, word.parts), else: {"", []}

    should_use_alt =
      if check_empty do
        value != nil and value != ""
      else
        value != nil
      end

    if should_use_alt, do: {alt_val, assigns}, else: {"", []}
  end

  defp expand_with_operation(bash, name, value, %AST.Length{}) do
    result =
      case parse_array_subscript(name) do
        {:array_all, arr_name} ->
          count_array_elements(bash, arr_name) |> to_string()

        {:array_index, arr_name, index_str} ->
          elem_value = expand_array_index(bash, arr_name, index_str)
          String.length(elem_value) |> to_string()

        :not_array ->
          String.length(value || "") |> to_string()
      end

    {result, []}
  end

  defp expand_with_operation(bash, _name, value, %AST.Substring{
         offset: offset_expr,
         length: length_expr
       }) do
    str = value || ""
    len = String.length(str)

    offset = eval_arith_or_number(offset_expr, bash.env)
    offset = if offset < 0, do: max(0, len + offset), else: offset

    result =
      case length_expr do
        nil ->
          String.slice(str, offset, len)

        _ ->
          length = eval_arith_or_number(length_expr, bash.env)
          length = if length < 0, do: max(0, len - offset + length), else: length
          String.slice(str, offset, length)
      end

    {result, []}
  end

  defp expand_with_operation(bash, _name, value, %AST.PatternRemoval{
         pattern: pattern_word,
         side: side,
         greedy: greedy
       }) do
    str = value || ""
    {pattern, assigns} = Expansion.expand_word_parts(bash, pattern_word.parts)
    regex_pattern = glob_to_regex(pattern)

    result =
      case side do
        :prefix -> remove_prefix(str, regex_pattern, greedy)
        :suffix -> remove_suffix(str, regex_pattern, greedy)
      end

    {result, assigns}
  end

  defp expand_with_operation(bash, _name, value, %AST.PatternReplacement{
         pattern: pattern_word,
         replacement: replacement_word,
         all: all,
         anchor: anchor
       }) do
    str = value || ""
    {pattern, assigns1} = Expansion.expand_word_parts(bash, pattern_word.parts)

    {replacement, assigns2} =
      if replacement_word,
        do: Expansion.expand_word_parts(bash, replacement_word.parts),
        else: {"", []}

    regex_pattern =
      case anchor do
        :start -> "^" <> glob_to_regex(pattern)
        :end -> glob_to_regex(pattern) <> "$"
        nil -> glob_to_regex(pattern)
      end

    result =
      case Regex.compile(regex_pattern) do
        {:ok, regex} ->
          if all do
            Regex.replace(regex, str, replacement, global: true)
          else
            Regex.replace(regex, str, replacement, global: false)
          end

        {:error, _} ->
          str
      end

    {result, assigns1 ++ assigns2}
  end

  defp expand_with_operation(_bash, _name, value, %AST.CaseModification{
         direction: direction,
         all: all
       }) do
    str = value || ""
    {apply_case_modification(str, direction, all), []}
  end

  defp expand_with_operation(bash, _name, value, %AST.Indirection{}) do
    var_name = value || ""
    {Map.get(bash.env, var_name, ""), []}
  end

  defp expand_with_operation(_bash, _name, value, %AST.ErrorIfUnset{
         word: _word,
         check_empty: check_empty
       }) do
    should_error =
      if check_empty do
        value == nil or value == ""
      else
        value == nil
      end

    result = if should_error, do: "", else: value || ""
    {result, []}
  end

  defp expand_with_operation(_bash, _name, value, _operation) do
    {value || "", []}
  end

  # Helper functions

  defp count_array_elements(bash, arr_name) do
    bash.env
    |> Enum.filter(fn {key, _} ->
      Regex.match?(~r/^#{Regex.escape(arr_name)}\[\d+\]$/, key)
    end)
    |> length()
  end

  defp apply_case_modification(str, _direction, true = _all) when str == "", do: ""
  defp apply_case_modification(str, :upper, true = _all), do: String.upcase(str)
  defp apply_case_modification(str, :lower, true = _all), do: String.downcase(str)

  defp apply_case_modification(str, direction, false = _all) do
    case String.graphemes(str) do
      [first | rest] -> apply_case_to_first(first, rest, direction)
      [] -> ""
    end
  end

  defp apply_case_to_first(first, rest, :upper), do: String.upcase(first) <> Enum.join(rest)
  defp apply_case_to_first(first, rest, :lower), do: String.downcase(first) <> Enum.join(rest)

  defp eval_arith_or_number(%AST.ArithmeticExpression{expression: expr}, env) do
    case Arithmetic.evaluate(expr, env) do
      {:ok, value, _} -> value
      {:error, :division_by_zero, _} -> raise ArithmeticError, message: "division by 0"
    end
  end

  defp eval_arith_or_number(%AST.ArithNumber{value: n}, _env), do: n

  defp eval_arith_or_number(expr, env) do
    case Arithmetic.evaluate(expr, env) do
      {:ok, value, _} -> value
      {:error, :division_by_zero, _} -> raise ArithmeticError, message: "division by 0"
    end
  end

  defp glob_to_regex(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join(fn
      "*" -> ".*"
      "?" -> "."
      c -> Regex.escape(c)
    end)
  end

  # Prefix/suffix removal

  defp remove_prefix(str, regex_pattern, greedy) do
    if greedy do
      find_longest_prefix(str, regex_pattern)
    else
      find_shortest_prefix(str, regex_pattern)
    end
  end

  defp remove_suffix(str, regex_pattern, greedy) do
    if greedy do
      find_longest_suffix(str, regex_pattern)
    else
      find_shortest_suffix(str, regex_pattern)
    end
  end

  defp find_shortest_prefix(str, regex_pattern) do
    case compile_anchored_regex(regex_pattern) do
      {:ok, regex} -> find_shortest_prefix_with_regex(str, regex)
      {:error, _} -> str
    end
  end

  defp find_shortest_prefix_with_regex(str, regex) do
    len = String.length(str)

    Enum.reduce_while(1..len, str, fn i, _acc ->
      prefix = String.slice(str, 0, i)

      if Regex.match?(regex, prefix) do
        {:halt, String.slice(str, i, len)}
      else
        {:cont, str}
      end
    end)
  end

  defp find_longest_prefix(str, regex_pattern) do
    case compile_anchored_regex(regex_pattern) do
      {:ok, regex} -> find_longest_prefix_with_regex(str, regex)
      {:error, _} -> str
    end
  end

  defp find_longest_prefix_with_regex(str, regex) do
    len = String.length(str)

    Enum.reduce(1..len, str, fn i, acc ->
      prefix = String.slice(str, 0, i)

      if Regex.match?(regex, prefix) do
        String.slice(str, i, len)
      else
        acc
      end
    end)
  end

  defp find_shortest_suffix(str, regex_pattern) do
    case compile_anchored_regex(regex_pattern) do
      {:ok, regex} -> find_shortest_suffix_with_regex(str, regex)
      {:error, _} -> str
    end
  end

  defp find_shortest_suffix_with_regex(str, regex) do
    len = String.length(str)

    Enum.reduce_while((len - 1)..0//-1, str, fn i, _acc ->
      suffix = String.slice(str, i, len)

      if Regex.match?(regex, suffix) do
        {:halt, String.slice(str, 0, i)}
      else
        {:cont, str}
      end
    end)
  end

  defp find_longest_suffix(str, regex_pattern) do
    case compile_anchored_regex(regex_pattern) do
      {:ok, regex} -> find_longest_suffix_with_regex(str, regex)
      {:error, _} -> str
    end
  end

  defp find_longest_suffix_with_regex(str, regex) do
    len = String.length(str)

    Enum.reduce_while(0..(len - 1), str, fn i, _acc ->
      suffix = String.slice(str, i, len)

      if Regex.match?(regex, suffix) do
        {:halt, String.slice(str, 0, i)}
      else
        {:cont, str}
      end
    end)
  end

  defp compile_anchored_regex(regex_pattern) do
    Regex.compile("^" <> regex_pattern <> "$")
  end
end
