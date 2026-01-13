defmodule JustBash.Commands.Jq.Parser do
  @moduledoc """
  Parser for jq filter expressions.

  Converts jq filter strings into an AST for evaluation.
  """

  @type ast ::
          :identity
          | :empty
          | {:field, String.t()}
          | {:index, integer()}
          | {:slice, integer() | nil, integer() | nil}
          | :iterate
          | {:optional, ast()}
          | {:pipe, ast(), ast()}
          | {:comma, [ast()]}
          | {:literal, any()}
          | {:array, [ast()]}
          | {:object, [{ast(), ast()}]}
          | {:func, atom(), [ast()]}
          | {:comparison, atom(), ast(), ast()}
          | {:boolean, atom(), ast(), ast()}
          | {:not, ast()}
          | {:try, ast()}
          | {:if, ast(), ast(), ast()}
          | {:recursive_descent}

  @doc """
  Parse a jq filter string into an AST.
  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, String.t()}
  def parse(filter) do
    filter = String.trim(filter)

    try do
      {ast, rest} = parse_pipe(filter)
      rest = String.trim(rest)

      if rest == "" do
        {:ok, ast}
      else
        {:error, "unexpected token: #{String.slice(rest, 0..20)}"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      {:parse_error, msg} -> {:error, msg}
    end
  end

  defp parse_pipe(input) do
    {left, rest} = parse_comma(input)
    rest = String.trim(rest)

    case rest do
      "|" <> rest2 ->
        {right, rest3} = parse_pipe(String.trim(rest2))
        {{:pipe, left, right}, rest3}

      _ ->
        {left, rest}
    end
  end

  defp parse_comma(input) do
    {first, rest} = parse_or(input)
    rest = String.trim(rest)
    parse_comma_tail([first], rest)
  end

  defp parse_comma_tail(acc, "," <> rest) do
    {expr, rest2} = parse_or(String.trim(rest))
    parse_comma_tail(acc ++ [expr], String.trim(rest2))
  end

  defp parse_comma_tail([single], rest), do: {single, rest}
  defp parse_comma_tail(acc, rest), do: {{:comma, acc}, rest}

  defp parse_or(input) do
    {left, rest} = parse_and(input)
    rest = String.trim(rest)

    if String.starts_with?(rest, "or") and not_ident_cont?(String.slice(rest, 2..-1//1)) do
      rest2 = String.slice(rest, 2..-1//1)
      {right, rest3} = parse_or(String.trim(rest2))
      {{:boolean, :or, left, right}, rest3}
    else
      {left, rest}
    end
  end

  defp parse_and(input) do
    {left, rest} = parse_not(input)
    rest = String.trim(rest)

    if String.starts_with?(rest, "and") and not_ident_cont?(String.slice(rest, 3..-1//1)) do
      rest2 = String.slice(rest, 3..-1//1)
      {right, rest3} = parse_and(String.trim(rest2))
      {{:boolean, :and, left, right}, rest3}
    else
      {left, rest}
    end
  end

  defp parse_not(input) do
    if String.starts_with?(input, "not") and not_ident_cont?(String.slice(input, 3..-1//1)) do
      rest = String.trim(String.slice(input, 3..-1//1))

      if not_as_function?(rest) do
        {{:func, :not, []}, rest}
      else
        {expr, rest2} = parse_not(rest)
        {{:not, expr}, rest2}
      end
    else
      parse_comparison(input)
    end
  end

  defp not_as_function?(rest) do
    rest == "" or String.starts_with?(rest, "|") or String.starts_with?(rest, ",") or
      String.starts_with?(rest, ")") or String.starts_with?(rest, "]") or
      String.starts_with?(rest, "}")
  end

  defp parse_comparison(input) do
    {left, rest} = parse_additive(input)
    rest = String.trim(rest)
    parse_comparison_op(left, rest)
  end

  defp parse_comparison_op(left, "==" <> rest), do: parse_comparison_rhs(:eq, left, rest)
  defp parse_comparison_op(left, "!=" <> rest), do: parse_comparison_rhs(:neq, left, rest)
  defp parse_comparison_op(left, "<=" <> rest), do: parse_comparison_rhs(:lte, left, rest)
  defp parse_comparison_op(left, ">=" <> rest), do: parse_comparison_rhs(:gte, left, rest)
  defp parse_comparison_op(left, "<" <> rest), do: parse_comparison_rhs(:lt, left, rest)
  defp parse_comparison_op(left, ">" <> rest), do: parse_comparison_rhs(:gt, left, rest)
  defp parse_comparison_op(left, rest), do: {left, rest}

  defp parse_comparison_rhs(op, left, rest) do
    {right, rest2} = parse_additive(String.trim(rest))
    {{:comparison, op, left, right}, rest2}
  end

  defp parse_additive(input) do
    {left, rest} = parse_multiplicative(input)
    parse_additive_tail(left, String.trim(rest))
  end

  defp parse_additive_tail(left, "+" <> rest) do
    {right, rest2} = parse_multiplicative(String.trim(rest))
    parse_additive_tail({:arith, :add, left, right}, String.trim(rest2))
  end

  defp parse_additive_tail(left, "-" <> rest) do
    {right, rest2} = parse_multiplicative(String.trim(rest))
    parse_additive_tail({:arith, :sub, left, right}, String.trim(rest2))
  end

  defp parse_additive_tail(left, rest), do: {left, rest}

  defp parse_multiplicative(input) do
    {left, rest} = parse_primary(input)
    parse_multiplicative_tail(left, String.trim(rest))
  end

  defp parse_multiplicative_tail(left, "*" <> rest) do
    {right, rest2} = parse_primary(String.trim(rest))
    parse_multiplicative_tail({:arith, :mul, left, right}, String.trim(rest2))
  end

  defp parse_multiplicative_tail(left, "/" <> rest) do
    {right, rest2} = parse_primary(String.trim(rest))
    parse_multiplicative_tail({:arith, :div, left, right}, String.trim(rest2))
  end

  defp parse_multiplicative_tail(left, "%" <> rest) do
    {right, rest2} = parse_primary(String.trim(rest))
    parse_multiplicative_tail({:arith, :mod, left, right}, String.trim(rest2))
  end

  defp parse_multiplicative_tail(left, rest), do: {left, rest}

  defp parse_primary(input) do
    input = String.trim(input)
    parse_primary_token(input)
  end

  defp parse_primary_token("." <> rest), do: parse_dot_expr(rest)
  defp parse_primary_token("[" <> rest), do: parse_array_construction(rest)
  defp parse_primary_token("{" <> rest), do: parse_object_construction(rest)
  defp parse_primary_token("(" <> rest), do: parse_parenthesized(rest)
  defp parse_primary_token("\"" <> _ = input), do: parse_string_literal(input)

  defp parse_primary_token("null" <> rest = input) do
    if not_ident_cont?(rest), do: {{:literal, nil}, rest}, else: parse_number_or_func(input)
  end

  defp parse_primary_token("true" <> rest = input) do
    if not_ident_cont?(rest), do: {{:literal, true}, rest}, else: parse_number_or_func(input)
  end

  defp parse_primary_token("false" <> rest = input) do
    if not_ident_cont?(rest), do: {{:literal, false}, rest}, else: parse_number_or_func(input)
  end

  defp parse_primary_token("empty" <> rest = input) do
    if not_ident_cont?(rest), do: {:empty, rest}, else: parse_number_or_func(input)
  end

  defp parse_primary_token("if" <> rest = input) do
    if not_ident_cont?(rest), do: parse_if_expr(rest), else: parse_number_or_func(input)
  end

  defp parse_primary_token("try" <> rest = input) do
    if not_ident_cont?(rest), do: parse_try_expr(rest), else: parse_number_or_func(input)
  end

  defp parse_primary_token(input), do: parse_number_or_func(input)

  defp not_ident_cont?(""), do: true

  defp not_ident_cont?(<<c, _::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: false

  defp not_ident_cont?(_), do: true

  defp parse_dot_expr("") do
    {:identity, ""}
  end

  defp parse_dot_expr("." <> rest) do
    {{:recursive_descent}, rest}
  end

  defp parse_dot_expr("[" <> rest) do
    {index_expr, rest2} = parse_index_expr(rest)
    {suffix, rest3} = parse_suffix(rest2)
    {apply_suffix(index_expr, suffix), rest3}
  end

  defp parse_dot_expr(rest) do
    case parse_identifier(rest) do
      {"", rest2} ->
        {suffix, rest3} = parse_suffix(rest2)
        {apply_suffix(:identity, suffix), rest3}

      {name, rest2} ->
        {suffix, rest3} = parse_suffix(rest2)
        {apply_suffix({:field, name}, suffix), rest3}
    end
  end

  defp parse_suffix(input) do
    input = String.trim(input)
    parse_suffix_token(input)
  end

  defp parse_suffix_token("?" <> rest) do
    {more_suffix, rest2} = parse_suffix(rest)
    {[:optional | more_suffix], rest2}
  end

  defp parse_suffix_token("[" <> rest) do
    {index_expr, rest2} = parse_index_expr(rest)
    {more_suffix, rest3} = parse_suffix(rest2)
    {[index_expr | more_suffix], rest3}
  end

  defp parse_suffix_token("." <> _ = input) do
    if String.starts_with?(input, "..") do
      {[], input}
    else
      parse_suffix_field(String.slice(input, 1..-1//1))
    end
  end

  defp parse_suffix_token(input), do: {[], input}

  defp parse_suffix_field(rest) do
    case parse_identifier(rest) do
      {"", _} ->
        {[], "." <> rest}

      {name, rest2} ->
        {more_suffix, rest3} = parse_suffix(rest2)
        {[{:field, name} | more_suffix], rest3}
    end
  end

  defp apply_suffix(base, []), do: base

  defp apply_suffix(base, [:optional | rest]) do
    apply_suffix({:optional, base}, rest)
  end

  defp apply_suffix(base, [expr | rest]) do
    apply_suffix({:pipe, base, expr}, rest)
  end

  defp parse_index_expr(input) do
    input = String.trim(input)

    if String.starts_with?(input, "]") do
      {:iterate, String.slice(input, 1..-1//1)}
    else
      parse_index_or_slice(input)
    end
  end

  defp parse_index_or_slice(input) do
    case parse_slice_or_index(input) do
      {:index, n, rest} ->
        rest = String.trim(rest)
        "]" <> rest2 = rest
        {{:index, n}, rest2}

      {:slice, start_idx, end_idx, rest} ->
        rest = String.trim(rest)
        "]" <> rest2 = rest
        {{:slice, start_idx, end_idx}, rest2}
    end
  end

  defp parse_slice_or_index(":" <> rest) do
    case parse_optional_int(String.trim(rest)) do
      {nil, rest2} -> {:slice, nil, nil, rest2}
      {n, rest2} -> {:slice, nil, n, rest2}
    end
  end

  defp parse_slice_or_index(input) do
    case parse_int(input) do
      {:ok, n, rest} ->
        rest = String.trim(rest)
        maybe_parse_slice_end(n, rest)

      :error ->
        throw({:parse_error, "expected index or slice"})
    end
  end

  defp maybe_parse_slice_end(n, ":" <> rest) do
    case parse_optional_int(String.trim(rest)) do
      {nil, rest2} -> {:slice, n, nil, rest2}
      {m, rest2} -> {:slice, n, m, rest2}
    end
  end

  defp maybe_parse_slice_end(n, rest), do: {:index, n, rest}

  defp parse_optional_int(input) do
    case parse_int(input) do
      {:ok, n, rest} -> {n, rest}
      :error -> {nil, input}
    end
  end

  defp parse_int(input) do
    case Integer.parse(input) do
      {n, rest} -> {:ok, n, rest}
      :error -> :error
    end
  end

  defp parse_identifier(input) do
    case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_]*)(.*)$/s, input) do
      [_, name, rest] -> {name, rest}
      nil -> {"", input}
    end
  end

  defp parse_array_construction(input) do
    input = String.trim(input)

    if String.starts_with?(input, "]") do
      {{:array, []}, String.slice(input, 1..-1//1)}
    else
      {expr, rest} = parse_pipe(input)
      rest = String.trim(rest)
      "]" <> rest2 = rest
      {{:array, [expr]}, rest2}
    end
  end

  defp parse_object_construction(input) do
    input = String.trim(input)

    if String.starts_with?(input, "}") do
      {{:object, []}, String.slice(input, 1..-1//1)}
    else
      {pairs, rest} = parse_object_pairs(input)
      {{:object, pairs}, rest}
    end
  end

  defp parse_object_pairs(input) do
    {pair, rest} = parse_object_pair(input)
    rest = String.trim(rest)
    parse_object_pairs_tail(pair, rest)
  end

  defp parse_object_pairs_tail(pair, "," <> rest) do
    {more_pairs, rest2} = parse_object_pairs(String.trim(rest))
    {[pair | more_pairs], rest2}
  end

  defp parse_object_pairs_tail(pair, "}" <> rest) do
    {[pair], rest}
  end

  defp parse_object_pairs_tail(_pair, rest) do
    throw({:parse_error, "expected ',' or '}' in object, got: #{String.slice(rest, 0..20)}"})
  end

  defp parse_object_pair(input) do
    input = String.trim(input)
    {key, rest} = parse_object_key(input)
    rest = String.trim(rest)
    ":" <> rest2 = rest
    {value, rest3} = parse_or(String.trim(rest2))
    {{key, value}, rest3}
  end

  defp parse_object_key("(" <> rest) do
    {expr, rest2} = parse_pipe(rest)
    rest2 = String.trim(rest2)
    ")" <> rest3 = rest2
    {expr, rest3}
  end

  defp parse_object_key("\"" <> _ = input), do: parse_string_literal(input)

  defp parse_object_key(input) do
    case parse_identifier(input) do
      {"", _} -> throw({:parse_error, "expected object key"})
      {name, rest} -> {{:literal, name}, rest}
    end
  end

  defp parse_parenthesized(input) do
    {expr, rest} = parse_pipe(input)
    rest = String.trim(rest)
    ")" <> rest2 = rest
    {expr, rest2}
  end

  defp parse_string_literal("\"" <> rest) do
    {str, rest2} = parse_string_content(rest, "")
    {{:literal, str}, rest2}
  end

  defp parse_string_content("\"" <> rest, acc), do: {acc, rest}
  defp parse_string_content("\\\"" <> rest, acc), do: parse_string_content(rest, acc <> "\"")
  defp parse_string_content("\\n" <> rest, acc), do: parse_string_content(rest, acc <> "\n")
  defp parse_string_content("\\t" <> rest, acc), do: parse_string_content(rest, acc <> "\t")
  defp parse_string_content("\\\\" <> rest, acc), do: parse_string_content(rest, acc <> "\\")

  defp parse_string_content(<<c::utf8, rest::binary>>, acc) do
    parse_string_content(rest, acc <> <<c::utf8>>)
  end

  defp parse_number_or_func(input) do
    case Float.parse(input) do
      {n, rest} ->
        parse_number_result(n, rest, input)

      :error ->
        parse_identifier_or_func(input)
    end
  end

  defp parse_number_result(n, rest, input) do
    if rest == "" or number_terminator?(rest) do
      n = if n == trunc(n), do: trunc(n), else: n
      {{:literal, n}, rest}
    else
      parse_identifier_or_func(input)
    end
  end

  @number_terminators [?\s, ?\t, ?\n, ?\r, ?), ?], ?,, ?}, ?|, ?;]

  defp number_terminator?(<<c, _::binary>>) when c in @number_terminators, do: true
  defp number_terminator?(_), do: false

  defp parse_identifier_or_func(input) do
    case parse_identifier(input) do
      {"", _} ->
        throw({:parse_error, "unexpected input: #{String.slice(input, 0..20)}"})

      {name, rest} ->
        rest = String.trim(rest)

        if String.starts_with?(rest, "(") do
          {args, rest3} = parse_func_args(String.slice(rest, 1..-1//1))
          {{:func, String.to_atom(name), args}, rest3}
        else
          {{:func, String.to_atom(name), []}, rest}
        end
    end
  end

  defp parse_func_args(input) do
    input = String.trim(input)

    if String.starts_with?(input, ")") do
      {[], String.slice(input, 1..-1//1)}
    else
      {arg, rest} = parse_pipe(input)
      rest = String.trim(rest)
      parse_func_args_tail([arg], rest)
    end
  end

  defp parse_func_args_tail(acc, ")" <> rest), do: {Enum.reverse(acc), rest}

  defp parse_func_args_tail(acc, ";" <> rest) do
    {arg, rest2} = parse_pipe(String.trim(rest))
    parse_func_args_tail([arg | acc], String.trim(rest2))
  end

  defp parse_if_expr(rest) do
    rest = String.trim(rest)
    {cond_expr, rest2} = parse_pipe(rest)
    rest2 = String.trim(rest2)
    "then" <> rest3 = rest2
    {then_expr, rest4} = parse_pipe(String.trim(rest3))
    rest4 = String.trim(rest4)
    parse_if_else(cond_expr, then_expr, rest4)
  end

  defp parse_if_else(cond_expr, then_expr, "else" <> rest) do
    {else_expr, rest2} = parse_pipe(String.trim(rest))
    rest2 = String.trim(rest2)
    "end" <> rest3 = rest2
    {{:if, cond_expr, then_expr, else_expr}, rest3}
  end

  defp parse_if_else(cond_expr, then_expr, "end" <> rest) do
    {{:if, cond_expr, then_expr, {:literal, nil}}, rest}
  end

  defp parse_try_expr(rest) do
    {expr, rest2} = parse_primary(String.trim(rest))
    {{:try, expr}, rest2}
  end
end
