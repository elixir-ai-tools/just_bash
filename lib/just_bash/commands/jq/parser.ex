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
      # If rest is empty or starts with a pipe/comma/closing bracket, treat as function
      if rest == "" or String.starts_with?(rest, "|") or String.starts_with?(rest, ",") or
           String.starts_with?(rest, ")") or String.starts_with?(rest, "]") or
           String.starts_with?(rest, "}") do
        {{:func, :not, []}, rest}
      else
        {expr, rest2} = parse_not(rest)
        {{:not, expr}, rest2}
      end
    else
      parse_comparison(input)
    end
  end

  defp parse_comparison(input) do
    {left, rest} = parse_additive(input)
    rest = String.trim(rest)

    cond do
      String.starts_with?(rest, "==") ->
        rest2 = String.slice(rest, 2..-1//1)
        {right, rest3} = parse_additive(String.trim(rest2))
        {{:comparison, :eq, left, right}, rest3}

      String.starts_with?(rest, "!=") ->
        rest2 = String.slice(rest, 2..-1//1)
        {right, rest3} = parse_additive(String.trim(rest2))
        {{:comparison, :neq, left, right}, rest3}

      String.starts_with?(rest, "<=") ->
        rest2 = String.slice(rest, 2..-1//1)
        {right, rest3} = parse_additive(String.trim(rest2))
        {{:comparison, :lte, left, right}, rest3}

      String.starts_with?(rest, ">=") ->
        rest2 = String.slice(rest, 2..-1//1)
        {right, rest3} = parse_additive(String.trim(rest2))
        {{:comparison, :gte, left, right}, rest3}

      String.starts_with?(rest, "<") ->
        rest2 = String.slice(rest, 1..-1//1)
        {right, rest3} = parse_additive(String.trim(rest2))
        {{:comparison, :lt, left, right}, rest3}

      String.starts_with?(rest, ">") ->
        rest2 = String.slice(rest, 1..-1//1)
        {right, rest3} = parse_additive(String.trim(rest2))
        {{:comparison, :gt, left, right}, rest3}

      true ->
        {left, rest}
    end
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

    cond do
      String.starts_with?(input, ".") ->
        parse_dot_expr(String.slice(input, 1..-1//1))

      String.starts_with?(input, "[") ->
        parse_array_construction(String.slice(input, 1..-1//1))

      String.starts_with?(input, "{") ->
        parse_object_construction(String.slice(input, 1..-1//1))

      String.starts_with?(input, "(") ->
        parse_parenthesized(String.slice(input, 1..-1//1))

      String.starts_with?(input, "\"") ->
        parse_string_literal(input)

      String.starts_with?(input, "null") and not_ident_cont?(String.slice(input, 4..-1//1)) ->
        {{:literal, nil}, String.slice(input, 4..-1//1)}

      String.starts_with?(input, "true") and not_ident_cont?(String.slice(input, 4..-1//1)) ->
        {{:literal, true}, String.slice(input, 4..-1//1)}

      String.starts_with?(input, "false") and not_ident_cont?(String.slice(input, 5..-1//1)) ->
        {{:literal, false}, String.slice(input, 5..-1//1)}

      String.starts_with?(input, "empty") and not_ident_cont?(String.slice(input, 5..-1//1)) ->
        {:empty, String.slice(input, 5..-1//1)}

      String.starts_with?(input, "if") and not_ident_cont?(String.slice(input, 2..-1//1)) ->
        parse_if_expr(String.slice(input, 2..-1//1))

      String.starts_with?(input, "try") and not_ident_cont?(String.slice(input, 3..-1//1)) ->
        parse_try_expr(String.slice(input, 3..-1//1))

      true ->
        parse_number_or_func(input)
    end
  end

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

    cond do
      String.starts_with?(input, "?") ->
        {more_suffix, rest2} = parse_suffix(String.slice(input, 1..-1//1))
        {[:optional | more_suffix], rest2}

      String.starts_with?(input, "[") ->
        {index_expr, rest2} = parse_index_expr(String.slice(input, 1..-1//1))
        {more_suffix, rest3} = parse_suffix(rest2)
        {[index_expr | more_suffix], rest3}

      String.starts_with?(input, ".") and not String.starts_with?(input, "..") ->
        rest = String.slice(input, 1..-1//1)

        case parse_identifier(rest) do
          {"", _} ->
            {[], input}

          {name, rest2} ->
            {more_suffix, rest3} = parse_suffix(rest2)
            {[{:field, name} | more_suffix], rest3}
        end

      true ->
        {[], input}
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
  end

  defp parse_slice_or_index(input) do
    if String.starts_with?(input, ":") do
      rest = String.slice(input, 1..-1//1)

      case parse_optional_int(String.trim(rest)) do
        {nil, rest2} -> {:slice, nil, nil, rest2}
        {n, rest2} -> {:slice, nil, n, rest2}
      end
    else
      case parse_int(input) do
        {:ok, n, rest} ->
          rest = String.trim(rest)

          if String.starts_with?(rest, ":") do
            rest2 = String.slice(rest, 1..-1//1)

            case parse_optional_int(String.trim(rest2)) do
              {nil, rest3} -> {:slice, n, nil, rest3}
              {m, rest3} -> {:slice, n, m, rest3}
            end
          else
            {:index, n, rest}
          end

        :error ->
          throw({:parse_error, "expected index or slice"})
      end
    end
  end

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

    cond do
      String.starts_with?(rest, ",") ->
        {more_pairs, rest3} = parse_object_pairs(String.trim(String.slice(rest, 1..-1//1)))
        {[pair | more_pairs], rest3}

      String.starts_with?(rest, "}") ->
        {[pair], String.slice(rest, 1..-1//1)}

      true ->
        throw({:parse_error, "expected ',' or '}' in object, got: #{String.slice(rest, 0..20)}"})
    end
  end

  defp parse_object_pair(input) do
    input = String.trim(input)

    {key, rest} =
      cond do
        String.starts_with?(input, "(") ->
          {expr, rest2} = parse_pipe(String.slice(input, 1..-1//1))
          rest2 = String.trim(rest2)
          ")" <> rest3 = rest2
          {expr, rest3}

        String.starts_with?(input, "\"") ->
          parse_string_literal(input)

        true ->
          case parse_identifier(input) do
            {"", _} -> throw({:parse_error, "expected object key"})
            {name, rest} -> {{:literal, name}, rest}
          end
      end

    rest = String.trim(rest)
    ":" <> rest2 = rest
    {value, rest3} = parse_or(String.trim(rest2))
    {{key, value}, rest3}
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
        if rest == "" or is_number_terminator?(rest) do
          n = if n == trunc(n), do: trunc(n), else: n
          {{:literal, n}, rest}
        else
          parse_identifier_or_func(input)
        end

      :error ->
        parse_identifier_or_func(input)
    end
  end

  defp is_number_terminator?(<<c, _::binary>>)
       when c == ?\s or c == ?\t or c == ?\n or c == ?\r or
              c == ?) or c == ?] or c == ?, or c == ?} or
              c == ?| or c == ?;,
       do: true

  defp is_number_terminator?(_), do: false

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

    cond do
      String.starts_with?(rest4, "else") ->
        rest5 = String.slice(rest4, 4..-1//1)
        {else_expr, rest6} = parse_pipe(String.trim(rest5))
        rest6 = String.trim(rest6)
        "end" <> rest7 = rest6
        {{:if, cond_expr, then_expr, else_expr}, rest7}

      String.starts_with?(rest4, "end") ->
        {{:if, cond_expr, then_expr, {:literal, nil}}, String.slice(rest4, 3..-1//1)}
    end
  end

  defp parse_try_expr(rest) do
    {expr, rest2} = parse_primary(String.trim(rest))
    {{:try, expr}, rest2}
  end
end
