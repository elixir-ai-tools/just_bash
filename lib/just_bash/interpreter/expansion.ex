defmodule JustBash.Interpreter.Expansion do
  @moduledoc """
  Handles shell expansion: variables, command substitution, arithmetic.
  """

  alias JustBash.Arithmetic
  alias JustBash.AST
  alias JustBash.Interpreter.Executor
  alias JustBash.Fs.InMemoryFs

  defmodule UnsetVariableError do
    @moduledoc "Raised when accessing an unset variable with set -u"
    defexception [:variable]

    @impl true
    def message(%{variable: var}), do: "#{var}: unbound variable"
  end

  @doc """
  Get any pending variable assignments from expansion (used by ${VAR:=default}).
  Returns a list of {name, value} tuples and clears the pending list.
  """
  def get_pending_assignments do
    assignments = Process.get(:expansion_assignments, [])
    Process.delete(:expansion_assignments)
    assignments
  end

  defp add_pending_assignment(name, value) do
    current = Process.get(:expansion_assignments, [])
    Process.put(:expansion_assignments, [{name, value} | current])
  end

  @doc """
  Expand word parts into a string, handling all substitution types.
  """
  @spec expand_word_parts(JustBash.t(), [AST.word_part()]) :: String.t()
  def expand_word_parts(bash, parts) do
    Enum.map_join(parts, "", &expand_part(bash, &1))
  end

  @doc """
  Expand word parts with brace and glob expansion, returning a list of strings.
  Used for command arguments where globs should expand to multiple files.

  Expansion order: brace -> parameter/command -> glob
  """
  @spec expand_word_with_glob(JustBash.t(), [AST.word_part()]) :: [String.t()]
  def expand_word_with_glob(bash, parts) do
    has_unquoted_glob = has_unquoted_glob?(parts)
    expanded_words = expand_with_brace_expansion(bash, parts)

    Enum.flat_map(expanded_words, fn word_str ->
      if has_unquoted_glob and has_glob_chars?(word_str) do
        expand_glob(bash, word_str)
      else
        [word_str]
      end
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

  defp has_glob_chars?(str) do
    String.contains?(str, "*") or String.contains?(str, "?") or
      Regex.match?(~r/\[[^\]]+\]/, str)
  end

  defp expand_with_brace_expansion(bash, parts) do
    case find_brace_expansion(parts) do
      nil ->
        [expand_word_parts(bash, parts)]

      {prefix_parts, brace_exp, suffix_parts} ->
        expanded_items = expand_brace_items(bash, brace_exp.items)

        Enum.flat_map(expanded_items, fn item ->
          new_parts = prefix_parts ++ [%AST.Literal{value: item}] ++ suffix_parts
          expand_with_brace_expansion(bash, new_parts)
        end)
    end
  end

  defp find_brace_expansion(parts) do
    find_brace_expansion_loop(parts, [])
  end

  defp find_brace_expansion_loop([], _prefix), do: nil

  defp find_brace_expansion_loop([%AST.BraceExpansion{} = brace | rest], prefix) do
    {Enum.reverse(prefix), brace, rest}
  end

  defp find_brace_expansion_loop([part | rest], prefix) do
    find_brace_expansion_loop(rest, [part | prefix])
  end

  defp expand_brace_items(bash, items) do
    Enum.flat_map(items, fn
      {:word, word} ->
        expand_with_brace_expansion(bash, word.parts)

      {:range, start_val, end_val, step} ->
        expand_range(start_val, end_val, step)
    end)
  end

  defp expand_range(start_val, end_val, step)
       when is_integer(start_val) and is_integer(end_val) do
    step = step || if start_val <= end_val, do: 1, else: -1

    if (step > 0 and start_val <= end_val) or (step < 0 and start_val >= end_val) do
      Range.new(start_val, end_val, step)
      |> Enum.map(&Integer.to_string/1)
    else
      []
    end
  end

  defp expand_range(start_val, end_val, step) when is_binary(start_val) and is_binary(end_val) do
    start_char = :binary.first(start_val)
    end_char = :binary.first(end_val)
    step = step || if start_char <= end_char, do: 1, else: -1

    if (step > 0 and start_char <= end_char) or (step < 0 and start_char >= end_char) do
      Range.new(start_char, end_char, step)
      |> Enum.map(&<<&1>>)
    else
      []
    end
  end

  defp expand_glob(bash, pattern) do
    dir = if String.starts_with?(pattern, "/"), do: "/", else: bash.cwd
    {dir_pattern, file_pattern} = split_glob_pattern(bash.cwd, dir, pattern)
    regex_pattern = glob_pattern_to_regex(file_pattern)

    with {:ok, regex} <- Regex.compile("^" <> regex_pattern <> "$"),
         {:ok, entries} <- InMemoryFs.readdir(bash.fs, dir_pattern) do
      matches = filter_and_format_glob_matches(entries, regex, dir_pattern, bash.cwd)
      if matches == [], do: [pattern], else: matches
    else
      _ -> [pattern]
    end
  end

  defp split_glob_pattern(cwd, dir, pattern) do
    case String.split(pattern, "/") |> Enum.reverse() do
      [file] ->
        {dir, file}

      [file | rest] ->
        dir_part = rest |> Enum.reverse() |> Enum.join("/")
        resolved_dir = resolve_glob_dir(cwd, dir_part)
        {resolved_dir, file}
    end
  end

  defp resolve_glob_dir(cwd, dir_part) do
    if String.starts_with?(dir_part, "/"),
      do: dir_part,
      else: InMemoryFs.resolve_path(cwd, dir_part)
  end

  defp filter_and_format_glob_matches(entries, regex, dir_pattern, cwd) do
    entries
    |> Enum.filter(fn entry ->
      Regex.match?(regex, entry) and not String.starts_with?(entry, ".")
    end)
    |> Enum.sort()
    |> Enum.map(fn entry ->
      if dir_pattern == cwd, do: entry, else: Path.join(dir_pattern, entry)
    end)
  end

  defp glob_pattern_to_regex(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join(fn
      "*" -> ".*"
      "?" -> "."
      "[" -> "["
      "]" -> "]"
      c -> Regex.escape(c)
    end)
  end

  defp expand_part(_bash, part) when is_binary(part), do: part

  defp expand_part(_bash, %AST.Literal{value: value}), do: value

  defp expand_part(_bash, %AST.SingleQuoted{value: value}), do: value

  defp expand_part(_bash, %AST.Escaped{value: value}), do: value

  defp expand_part(bash, %AST.DoubleQuoted{parts: parts}) do
    expand_word_parts(bash, parts)
  end

  defp expand_part(bash, %AST.ParameterExpansion{} = param) do
    expand_parameter(bash, param)
  end

  defp expand_part(bash, %AST.CommandSubstitution{body: body}) do
    execute_command_substitution(bash, body)
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

  defp expand_part(_bash, %AST.Glob{pattern: pattern}), do: pattern

  defp expand_part(bash, %AST.TildeExpansion{user: nil}) do
    Map.get(bash.env, "HOME", "~")
  end

  defp expand_part(_bash, %AST.TildeExpansion{user: user}), do: "~#{user}"

  defp expand_part(_bash, _), do: ""

  defp execute_arithmetic_expansion(bash, %AST.ArithmeticExpression{expression: inner_expr}) do
    {value, _env} = Arithmetic.evaluate(inner_expr, bash.env)
    to_string(value)
  end

  defp execute_arithmetic_expansion(bash, expr) do
    {value, _env} = Arithmetic.evaluate(expr, bash.env)
    to_string(value)
  end

  defp execute_command_substitution(bash, %AST.Script{} = script) do
    {result, _bash} = Executor.execute_script(bash, script)
    String.trim_trailing(result.stdout, "\n")
  end

  @doc """
  Expand a parameter with optional operations.
  """
  @spec expand_parameter(JustBash.t(), AST.ParameterExpansion.t()) :: String.t()
  def expand_parameter(bash, %AST.ParameterExpansion{parameter: name, operation: nil}) do
    case Map.fetch(bash.env, name) do
      {:ok, value} ->
        value

      :error ->
        # Check nounset - error if variable is unset and nounset is enabled
        # Special variables like $?, $#, etc. are always considered set
        if bash.shell_opts.nounset and not special_variable?(name) do
          raise UnsetVariableError, variable: name
        else
          ""
        end
    end
  end

  def expand_parameter(bash, %AST.ParameterExpansion{parameter: name, operation: operation}) do
    value = Map.get(bash.env, name)

    # For operations like ${var:-default}, we don't error on unset even with nounset
    # because the operation handles the unset case
    expand_with_operation(bash, name, value, operation)
  end

  # Special variables that are always considered "set" for nounset purposes
  defp special_variable?(name) when name in ["?", "$", "!", "#", "*", "@", "-", "0"], do: true
  defp special_variable?(name), do: String.match?(name, ~r/^[0-9]+$/)

  defp expand_with_operation(bash, _name, value, %AST.DefaultValue{
         word: word,
         check_empty: check_empty
       }) do
    default_val = if word, do: expand_word_parts(bash, word.parts), else: ""

    should_use_default =
      if check_empty do
        value == nil or value == ""
      else
        value == nil
      end

    if should_use_default, do: default_val, else: value || ""
  end

  defp expand_with_operation(bash, name, value, %AST.AssignDefault{
         word: word,
         check_empty: check_empty
       }) do
    default_val = if word, do: expand_word_parts(bash, word.parts), else: ""

    should_assign =
      if check_empty do
        value == nil or value == ""
      else
        value == nil
      end

    if should_assign do
      # Record the assignment to be applied later
      add_pending_assignment(name, default_val)
      default_val
    else
      value || ""
    end
  end

  defp expand_with_operation(bash, _name, value, %AST.UseAlternative{
         word: word,
         check_empty: check_empty
       }) do
    alt_val = if word, do: expand_word_parts(bash, word.parts), else: ""

    should_use_alt =
      if check_empty do
        value != nil and value != ""
      else
        value != nil
      end

    if should_use_alt, do: alt_val, else: ""
  end

  defp expand_with_operation(_bash, _name, value, %AST.Length{}) do
    String.length(value || "") |> to_string()
  end

  defp expand_with_operation(bash, _name, value, %AST.Substring{
         offset: offset_expr,
         length: length_expr
       }) do
    str = value || ""
    len = String.length(str)

    offset = eval_arith_or_number(offset_expr, bash.env)
    offset = if offset < 0, do: max(0, len + offset), else: offset

    case length_expr do
      nil ->
        String.slice(str, offset, len)

      _ ->
        length = eval_arith_or_number(length_expr, bash.env)
        length = if length < 0, do: max(0, len - offset + length), else: length
        String.slice(str, offset, length)
    end
  end

  defp expand_with_operation(bash, _name, value, %AST.PatternRemoval{
         pattern: pattern_word,
         side: side,
         greedy: greedy
       }) do
    str = value || ""
    pattern = expand_word_parts(bash, pattern_word.parts)
    regex_pattern = glob_to_regex(pattern)

    case side do
      :prefix ->
        remove_prefix(str, regex_pattern, greedy)

      :suffix ->
        remove_suffix(str, regex_pattern, greedy)
    end
  end

  defp expand_with_operation(bash, _name, value, %AST.PatternReplacement{
         pattern: pattern_word,
         replacement: replacement_word,
         all: all,
         anchor: anchor
       }) do
    str = value || ""
    pattern = expand_word_parts(bash, pattern_word.parts)

    replacement =
      if replacement_word, do: expand_word_parts(bash, replacement_word.parts), else: ""

    regex_pattern =
      case anchor do
        :start -> "^" <> glob_to_regex(pattern)
        :end -> glob_to_regex(pattern) <> "$"
        nil -> glob_to_regex(pattern)
      end

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
  end

  defp expand_with_operation(_bash, _name, value, %AST.CaseModification{
         direction: direction,
         all: all
       }) do
    str = value || ""
    apply_case_modification(str, direction, all)
  end

  defp expand_with_operation(bash, _name, value, %AST.Indirection{}) do
    var_name = value || ""
    Map.get(bash.env, var_name, "")
  end

  defp expand_with_operation(_bash, _name, value, %AST.ErrorIfUnset{
         word: word,
         check_empty: check_empty
       }) do
    should_error =
      if check_empty do
        value == nil or value == ""
      else
        value == nil
      end

    if should_error do
      _error_msg = if word, do: "parameter null or not set", else: "parameter null or not set"
      ""
    else
      value || ""
    end
  end

  defp expand_with_operation(_bash, _name, value, _operation) do
    value || ""
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
    {value, _} = Arithmetic.evaluate(expr, env)
    value
  end

  defp eval_arith_or_number(%AST.ArithNumber{value: n}, _env), do: n

  defp eval_arith_or_number(expr, env) do
    {value, _} = Arithmetic.evaluate(expr, env)
    value
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

  defp remove_prefix(str, regex_pattern, greedy) do
    if greedy do
      find_longest_prefix(str, regex_pattern)
    else
      find_shortest_prefix(str, regex_pattern)
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

  defp remove_suffix(str, regex_pattern, greedy) do
    if greedy do
      find_longest_suffix(str, regex_pattern)
    else
      find_shortest_suffix(str, regex_pattern)
    end
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

  @doc """
  Expand redirection target.
  """
  @spec expand_redirect_target(JustBash.t(), AST.Word.t() | String.t() | any()) :: String.t()
  def expand_redirect_target(bash, %AST.Word{parts: parts}) do
    expand_word_parts(bash, parts)
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
    if has_brace_expansion?(parts) do
      expand_word_with_glob(bash, parts)
    else
      expand_for_loop_word_no_brace(bash, parts, ifs)
    end
  end

  defp has_brace_expansion?(parts) do
    Enum.any?(parts, fn
      %AST.BraceExpansion{} -> true
      _ -> false
    end)
  end

  defp expand_for_loop_word_no_brace(bash, parts, ifs) do
    has_unquoted_glob = has_unquoted_glob?(parts)
    expanded_segments = Enum.map(parts, &expand_for_loop_part(bash, &1, ifs))
    needs_ifs_split = Enum.any?(expanded_segments, fn {_, split?} -> split? end)
    combined = Enum.map_join(expanded_segments, "", fn {str, _} -> str end)
    results = maybe_split_on_ifs(combined, ifs, needs_ifs_split)
    maybe_expand_globs(bash, results, has_unquoted_glob)
  end

  defp maybe_split_on_ifs(combined, ifs, true = _needs_split) when ifs != "" do
    split_on_ifs(combined, ifs)
  end

  defp maybe_split_on_ifs(combined, _ifs, _needs_split), do: [combined]

  defp maybe_expand_globs(_bash, results, false = _has_glob), do: results

  defp maybe_expand_globs(bash, results, true = _has_glob) do
    Enum.flat_map(results, &expand_if_glob(bash, &1))
  end

  defp expand_if_glob(bash, word_str) do
    if has_glob_chars?(word_str), do: expand_glob(bash, word_str), else: [word_str]
  end

  defp expand_for_loop_part(_bash, %AST.Literal{value: value}, _ifs) do
    {value, false}
  end

  defp expand_for_loop_part(_bash, %AST.SingleQuoted{value: value}, _ifs) do
    {value, false}
  end

  defp expand_for_loop_part(bash, %AST.DoubleQuoted{parts: parts}, _ifs) do
    {expand_word_parts(bash, parts), false}
  end

  defp expand_for_loop_part(_bash, %AST.Escaped{value: value}, _ifs) do
    {value, false}
  end

  defp expand_for_loop_part(bash, %AST.ParameterExpansion{} = param, _ifs) do
    {expand_parameter(bash, param), true}
  end

  defp expand_for_loop_part(bash, %AST.CommandSubstitution{body: body}, _ifs) do
    {execute_command_substitution(bash, body), true}
  end

  defp expand_for_loop_part(bash, %AST.ArithmeticExpansion{expression: expr}, _ifs) do
    {execute_arithmetic_expansion(bash, expr), true}
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

  defp split_on_ifs(str, ifs) when ifs == "" do
    [str]
  end

  defp split_on_ifs(str, ifs) do
    ifs_chars = String.graphemes(ifs)
    regex_pattern = "[" <> Regex.escape(Enum.join(ifs_chars)) <> "]+"

    case Regex.compile(regex_pattern) do
      {:ok, regex} ->
        String.split(str, regex, trim: true)

      {:error, _} ->
        String.split(str, ~r/\s+/, trim: true)
    end
  end
end
