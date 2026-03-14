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
          | {:try, ast(), ast() | nil}
          | {:if, ast(), ast(), ast()}
          | {:recursive_descent}

  @doc """
  Parse a jq filter string into an AST.
  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, String.t()}
  def parse(filter) do
    filter = String.trim(filter)

    try do
      # Parse module directives (import, include, module) first
      {directives, rest} = parse_module_directives(filter, [])
      {ast, rest2} = parse_pipe(rest)
      rest2 = String.trim(rest2)

      if rest2 == "" do
        # Wrap AST with directives
        ast = wrap_with_directives(directives, ast)
        {:ok, ast}
      else
        {:error, "unexpected token: #{String.slice(rest2, 0..20)}"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      {:parse_error, msg} -> {:error, msg}
    end
  end

  # Parse module-level directives: import, include, module
  defp parse_module_directives(input, acc) do
    trimmed = String.trim(input)

    cond do
      keyword_ahead?(trimmed, "import") ->
        rest = String.trim(skip_keyword(trimmed, "import"))
        {directive, rest2} = parse_import_directive(rest)
        parse_module_directives(rest2, acc ++ [directive])

      keyword_ahead?(trimmed, "include") ->
        rest = String.trim(skip_keyword(trimmed, "include"))
        {directive, rest2} = parse_include_directive(rest)
        parse_module_directives(rest2, acc ++ [directive])

      keyword_ahead?(trimmed, "module") ->
        rest = String.trim(skip_keyword(trimmed, "module"))
        {directive, rest2} = parse_module_declaration(rest)
        parse_module_directives(rest2, acc ++ [directive])

      true ->
        {acc, trimmed}
    end
  end

  defp parse_import_directive(input) do
    # import "path" as name; or import "path" as name {metadata};
    # import "path" as $name; (data import)
    {path, rest} = parse_jq_string_literal(input)
    rest = String.trim(rest)

    # Expect "as"
    unless keyword_ahead?(rest, "as") do
      throw({:parse_error, "expected 'as' in import"})
    end

    rest = String.trim(skip_keyword(rest, "as"))

    # Parse the alias name (could be $var or plain name)
    {alias_name, is_data, rest} =
      if String.starts_with?(rest, "$") do
        {name, rest2} = parse_identifier(String.slice(rest, 1..-1//1))
        {"$" <> name, true, rest2}
      else
        {name, rest2} = parse_identifier(rest)
        {name, false, rest2}
      end

    rest = String.trim(rest)

    # Optional metadata object
    {metadata, rest} =
      if String.starts_with?(rest, "{") do
        parse_metadata_object(rest)
      else
        {%{}, rest}
      end

    # Expect semicolon
    rest = String.trim(rest)

    rest =
      if String.starts_with?(rest, ";") do
        String.trim(String.slice(rest, 1..-1//1))
      else
        rest
      end

    {{:import, path, alias_name, is_data, metadata}, rest}
  end

  defp parse_include_directive(input) do
    # include "path"; or include "path" {metadata};
    {path, rest} = parse_jq_string_literal(input)
    rest = String.trim(rest)

    # Optional metadata
    {metadata, rest} =
      if String.starts_with?(rest, "{") do
        parse_metadata_object(rest)
      else
        {%{}, rest}
      end

    rest = String.trim(rest)

    rest =
      if String.starts_with?(rest, ";") do
        String.trim(String.slice(rest, 1..-1//1))
      else
        rest
      end

    {{:include, path, metadata}, rest}
  end

  defp parse_module_declaration(input) do
    # module {metadata};
    {metadata, rest} = parse_metadata_object(input)
    rest = String.trim(rest)

    rest =
      if String.starts_with?(rest, ";") do
        String.trim(String.slice(rest, 1..-1//1))
      else
        rest
      end

    {{:module_meta, metadata}, rest}
  end

  # Parse a simple jq string literal "..."
  defp parse_jq_string_literal(input) do
    unless String.starts_with?(input, "\"") do
      throw({:parse_error, "expected string literal"})
    end

    rest = String.slice(input, 1..-1//1)
    {chars, rest} = collect_string_chars(rest, [])
    {IO.iodata_to_binary(chars), rest}
  end

  defp collect_string_chars("", _acc), do: throw({:parse_error, "unterminated string"})

  defp collect_string_chars(<<?", rest::binary>>, acc) do
    {Enum.reverse(acc), rest}
  end

  defp collect_string_chars(<<?\\, c, rest::binary>>, acc) do
    char =
      case c do
        ?n -> "\n"
        ?t -> "\t"
        ?r -> "\r"
        ?\\ -> "\\"
        ?" -> "\""
        _ -> <<c>>
      end

    collect_string_chars(rest, [char | acc])
  end

  defp collect_string_chars(<<c, rest::binary>>, acc) do
    collect_string_chars(rest, [<<c>> | acc])
  end

  # Parse a metadata object like {search:"./"}
  defp parse_metadata_object(input) do
    unless String.starts_with?(input, "{") do
      throw({:parse_error, "expected metadata object"})
    end

    # Use the existing object parser but extract as a simple map
    {ast, rest} = parse_primary(input)

    case ast do
      {:object, _pairs} ->
        # We need to evaluate this to a map at parse time
        # For simplicity, use a mini-evaluator for constant objects
        map = eval_const_object(ast)
        {map, rest}

      _ ->
        {%{}, rest}
    end
  end

  defp eval_const_object({:object, pairs}) do
    Map.new(pairs, fn
      {{:literal, key}, {:literal, val}} -> {key, val}
      {{:literal, key}, :identity} -> {key, nil}
      _ -> throw({:parse_error, "module metadata must be constant"})
    end)
  end

  defp wrap_with_directives([], ast), do: ast

  defp wrap_with_directives(directives, ast) do
    {:module_directives, directives, ast}
  end

  defp parse_pipe(input) do
    {left, rest} = parse_comma(input)
    rest = String.trim(rest)

    # Check for `as` binding: EXPR as PATTERN | BODY
    if keyword_ahead?(rest, "as") do
      rest2 = String.trim(skip_keyword(rest, "as"))
      {pattern, rest3} = parse_as_pattern(rest2)
      rest3 = String.trim(rest3)

      # Check for ?// (try-alternative pattern)
      {patterns, rest4} = parse_try_alt_patterns([pattern], rest3)

      "|" <> rest5 = rest4
      {body, rest6} = parse_pipe(String.trim(rest5))
      {{:as, left, patterns, body}, rest6}
    else
      case rest do
        "|" <> rest2 ->
          {right, rest3} = parse_pipe(String.trim(rest2))
          {{:pipe, left, right}, rest3}

        _ ->
          {left, rest}
      end
    end
  end

  # Parse ?// chain of alternative patterns
  defp parse_try_alt_patterns(acc, "?//" <> rest) do
    rest = String.trim(rest)
    {pattern, rest2} = parse_as_pattern(rest)
    parse_try_alt_patterns(acc ++ [pattern], String.trim(rest2))
  end

  defp parse_try_alt_patterns([single], rest), do: {single, rest}
  defp parse_try_alt_patterns(acc, rest), do: {{:try_alt_patterns, acc}, rest}

  # Parse a destructuring pattern for `as`
  defp parse_as_pattern("$" <> rest) do
    {name, rest2} = parse_identifier(rest)
    if name == "", do: throw({:parse_error, "expected variable name after $"})
    {{:pat_var, name}, rest2}
  end

  defp parse_as_pattern("[" <> rest) do
    {patterns, rest2} = parse_array_pattern(String.trim(rest))
    {{:pat_array, patterns}, rest2}
  end

  defp parse_as_pattern("{" <> rest) do
    {patterns, rest2} = parse_object_pattern(String.trim(rest))
    {{:pat_object, patterns}, rest2}
  end

  defp parse_as_pattern(input) do
    throw({:parse_error, "expected pattern after 'as', got: #{String.slice(input, 0..20)}"})
  end

  defp parse_array_pattern("]" <> _rest) do
    throw({:parse_error, "expected binding variable or pattern, got ']'"})
  end

  defp parse_array_pattern(input) do
    {pat, rest} = parse_as_pattern(input)
    rest = String.trim(rest)

    case rest do
      "]" <> rest2 ->
        {[pat], rest2}

      "," <> rest2 ->
        {more, rest3} = parse_array_pattern(String.trim(rest2))
        {[pat | more], rest3}

      _ ->
        throw({:parse_error, "expected ',' or ']' in array pattern"})
    end
  end

  defp parse_object_pattern("}" <> _rest) do
    throw({:parse_error, "expected binding variable or pattern, got '}'"})
  end

  defp parse_object_pattern(input) do
    {pair, rest} = parse_object_pattern_pair(input)
    rest = String.trim(rest)

    case rest do
      "}" <> rest2 ->
        {[pair], rest2}

      "," <> rest2 ->
        {more, rest3} = parse_object_pattern(String.trim(rest2))
        {[pair | more], rest3}

      _ ->
        throw({:parse_error, "expected ',' or '}' in object pattern"})
    end
  end

  defp parse_object_pattern_pair("$" <> rest) do
    # Shorthand: {$a} means {a: $a}
    {name, rest2} = parse_identifier(rest)
    if name == "", do: throw({:parse_error, "expected variable name"})
    rest2 = String.trim(rest2)

    case rest2 do
      ":" <> rest3 ->
        # {$b: [$c, $d]} — $b is a key whose value destructures into pattern
        {pat, rest4} = parse_as_pattern(String.trim(rest3))
        {{:var_key, name, pat}, rest4}

      _ ->
        {{name, {:pat_var, name}}, rest2}
    end
  end

  defp parse_object_pattern_pair("\"" <> _ = input) do
    {key_ast, rest} = parse_string_literal(input)

    key =
      case key_ast do
        {:literal, s} when is_binary(s) -> s
        _ -> throw({:parse_error, "expected simple string key in object pattern"})
      end

    rest = String.trim(rest)
    ":" <> rest2 = rest
    {pat, rest3} = parse_as_pattern(String.trim(rest2))
    {{key, pat}, rest3}
  end

  defp parse_object_pattern_pair("(" <> rest) do
    {key_expr, rest2} = parse_pipe(rest)
    rest2 = String.trim(rest2)
    ")" <> rest3 = rest2
    rest3 = String.trim(rest3)
    ":" <> rest4 = rest3
    {pat, rest5} = parse_as_pattern(String.trim(rest4))
    {{:expr_key, key_expr, pat}, rest5}
  end

  defp parse_object_pattern_pair(input) do
    {name, rest} = parse_identifier(input)
    if name == "", do: throw({:parse_error, "expected key in object pattern"})
    rest = String.trim(rest)

    case rest do
      ":" <> rest2 ->
        {pat, rest3} = parse_as_pattern(String.trim(rest2))
        {{name, pat}, rest3}

      _ ->
        # Shorthand {a} means {a: .a} — but in patterns, this is {a: $a}? No.
        # In jq, {a} in patterns means bind .a to... well actually shorthand
        # identifiers in as patterns aren't standard. Let's just require :.
        throw({:parse_error, "expected ':' after key '#{name}' in object pattern"})
    end
  end

  defp parse_comma(input) do
    {first, rest} = parse_or(input)
    rest = String.trim(rest)
    parse_comma_tail([first], rest)
  end

  # Don't consume comma if it's followed by something that looks like
  # the start of another object pair (for {a:1, b:2} cases)
  defp parse_comma_tail(acc, "," <> rest) do
    {expr, rest2} = parse_or(String.trim(rest))
    parse_comma_tail(acc ++ [expr], String.trim(rest2))
  end

  defp parse_comma_tail([single], rest), do: {single, rest}
  defp parse_comma_tail(acc, rest), do: {{:comma, acc}, rest}

  defp parse_or(input) do
    {left, rest} = parse_update_assign(input)
    rest = String.trim(rest)

    if keyword_ahead?(rest, "or") do
      rest2 = skip_keyword(rest, "or")
      {right, rest3} = parse_or(String.trim(rest2))
      {{:boolean, :or, left, right}, rest3}
    else
      {left, rest}
    end
  end

  # Update/plain assignment operators: =, +=, -=, *=, /=, %=, //=, |=
  defp parse_update_assign(input) do
    {left, rest} = parse_alternative(input)
    rest = String.trim(rest)

    cond do
      String.starts_with?(rest, "//=") ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 3..-1//1)))
        {{:update_assign, :alt, left, right}, rest2}

      String.starts_with?(rest, "+=") ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 2..-1//1)))
        {{:update_assign, :add, left, right}, rest2}

      String.starts_with?(rest, "-=") ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 2..-1//1)))
        {{:update_assign, :sub, left, right}, rest2}

      String.starts_with?(rest, "*=") ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 2..-1//1)))
        {{:update_assign, :mul, left, right}, rest2}

      String.starts_with?(rest, "|=") ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 2..-1//1)))
        {{:update_assign, :pipe, left, right}, rest2}

      String.starts_with?(rest, "%=") ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 2..-1//1)))
        {{:update_assign, :mod, left, right}, rest2}

      String.starts_with?(rest, "/=") ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 2..-1//1)))
        {{:update_assign, :div, left, right}, rest2}

      # Plain assignment: = (but not ==)
      match?(<<"=", c, _::binary>> when c != ?=, rest) ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 1..-1//1)))
        {{:assign, left, right}, rest2}

      rest == "=" ->
        {right, rest2} = parse_update_assign(String.trim(String.slice(rest, 1..-1//1)))
        {{:assign, left, right}, rest2}

      true ->
        {left, rest}
    end
  end

  # // (alternative operator) - returns left if not false/null, else right
  defp parse_alternative(input) do
    {left, rest} = parse_and(input)
    rest = String.trim(rest)

    cond do
      # Don't match //= (update alternative assignment)
      String.starts_with?(rest, "//=") ->
        {left, rest}

      String.starts_with?(rest, "//") ->
        rest2 = String.slice(rest, 2..-1//1)
        {right, rest3} = parse_alternative(String.trim(rest2))
        {{:alternative, left, right}, rest3}

      true ->
        {left, rest}
    end
  end

  defp parse_and(input) do
    {left, rest} = parse_not(input)
    rest = String.trim(rest)

    if keyword_ahead?(rest, "and") do
      rest2 = skip_keyword(rest, "and")
      {right, rest3} = parse_and(String.trim(rest2))
      {{:boolean, :and, left, right}, rest3}
    else
      {left, rest}
    end
  end

  defp parse_not(input) do
    if keyword_ahead?(input, "not") do
      rest = String.trim(skip_keyword(input, "not"))

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
      String.starts_with?(rest, "}") or String.starts_with?(rest, ";")
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

  # Don't match += or -= (update assignment operators) as arithmetic
  defp parse_additive_tail(left, "+=" <> _rest = input), do: {left, input}
  defp parse_additive_tail(left, "-=" <> _rest = input), do: {left, input}

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
    {left, rest} = parse_unary(input)
    parse_multiplicative_tail(left, String.trim(rest))
  end

  # Don't match *= or /= or %= (update assignment operators) as arithmetic
  defp parse_multiplicative_tail(left, "*=" <> _rest = input), do: {left, input}
  defp parse_multiplicative_tail(left, "/=" <> _rest = input), do: {left, input}
  defp parse_multiplicative_tail(left, "%=" <> _rest = input), do: {left, input}

  defp parse_multiplicative_tail(left, "*" <> rest) do
    {right, rest2} = parse_unary(String.trim(rest))
    parse_multiplicative_tail({:arith, :mul, left, right}, String.trim(rest2))
  end

  # Don't match // (alternative operator) or //= (update alternative) as division
  defp parse_multiplicative_tail(left, "//" <> _rest = input), do: {left, input}

  defp parse_multiplicative_tail(left, "/" <> rest) do
    {right, rest2} = parse_unary(String.trim(rest))
    parse_multiplicative_tail({:arith, :div, left, right}, String.trim(rest2))
  end

  defp parse_multiplicative_tail(left, "%" <> rest) do
    {right, rest2} = parse_unary(String.trim(rest))
    parse_multiplicative_tail({:arith, :mod, left, right}, String.trim(rest2))
  end

  defp parse_multiplicative_tail(left, rest), do: {left, rest}

  # Unary minus: -EXPR
  defp parse_unary("-" <> _rest = input) do
    after_minus = String.trim(String.slice(input, 1..-1//1))

    # Check if this is a negative number literal
    case parse_scientific_or_float(after_minus) do
      {:ok, n, num_rest} ->
        if num_rest == "" or number_terminator?(num_rest) do
          n = -n

          n =
            if is_float(n) and n == trunc(n) and
                 not has_decimal_or_exponent?(after_minus, num_rest),
               do: trunc(n),
               else: n

          parse_postfix({{:literal, n}, num_rest})
        else
          # Not a simple number, parse as unary minus
          parse_unary_negation(after_minus)
        end

      :error ->
        # Not a number at all, parse as unary minus on expression
        parse_unary_negation(after_minus)
    end
  end

  defp parse_unary(input), do: parse_postfix(parse_primary(input))

  defp parse_unary_negation(input) do
    {expr, rest} = parse_unary(input)
    {{:arith, :sub, {:literal, 0}, expr}, rest}
  end

  # Handle postfix operations like suffix chains after primary
  # Also handles `?//` as a postfix try-alternative
  defp parse_postfix({expr, rest}) do
    rest = String.trim(rest)

    cond do
      # Postfix ? for optional
      String.starts_with?(rest, "?//") ->
        # ?// (try-alternative operator) — parsed at binding level, not here
        # Actually ?// is a postfix operator on expressions too: .foo?//null
        rest2 = String.trim(String.slice(rest, 3..-1//1))
        {alt, rest3} = parse_unary(rest2)
        parse_postfix({{:try_alt, expr, alt}, rest3})

      String.starts_with?(rest, "?") and not String.starts_with?(rest, "?//") ->
        parse_postfix({{:optional, expr}, String.slice(rest, 1..-1//1)})

      # Postfix [] or [expr] indexing after any expression
      String.starts_with?(rest, "[") ->
        {index_expr, rest2} = parse_index_expr(String.slice(rest, 1..-1//1))
        parse_postfix({make_postfix_index(expr, index_expr), rest2})

      # Postfix .field access or .[] iteration
      String.starts_with?(rest, ".") and not String.starts_with?(rest, "..") ->
        after_dot = String.slice(rest, 1..-1//1)

        cond do
          # .[...] — index/iterate after dot
          String.starts_with?(after_dot, "[") ->
            {index_expr, rest2} = parse_index_expr(String.slice(after_dot, 1..-1//1))
            parse_postfix({make_postfix_index(expr, index_expr), rest2})

          # ."string" field access
          String.starts_with?(after_dot, "\"") ->
            {str_ast, rest2} = parse_string_literal(after_dot)

            key =
              case str_ast do
                {:literal, s} when is_binary(s) -> s
                _ -> throw({:parse_error, "expected simple string field name"})
              end

            parse_postfix({{:pipe, expr, {:field, key}}, rest2})

          true ->
            case parse_identifier(after_dot) do
              {"", _} ->
                {expr, rest}

              {name, rest2} ->
                parse_postfix({{:pipe, expr, {:field, name}}, rest2})
            end
        end

      true ->
        {expr, rest}
    end
  end

  defp parse_primary(input) do
    input = String.trim(input)
    parse_primary_token(input)
  end

  defp parse_primary_token("." <> rest), do: parse_dot_expr(rest)
  defp parse_primary_token("[" <> rest), do: parse_array_construction(rest)
  defp parse_primary_token("{" <> rest), do: parse_object_construction(rest)
  defp parse_primary_token("(" <> rest), do: parse_parenthesized(rest)
  defp parse_primary_token("\"" <> _ = input), do: parse_string_literal(input)
  defp parse_primary_token("@" <> rest), do: parse_format_string(rest)

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

  defp parse_primary_token("reduce" <> rest = input) do
    if not_ident_cont?(rest), do: parse_reduce_expr(rest), else: parse_number_or_func(input)
  end

  defp parse_primary_token("foreach" <> rest = input) do
    if not_ident_cont?(rest), do: parse_foreach_expr(rest), else: parse_number_or_func(input)
  end

  defp parse_primary_token("def" <> rest = input) do
    if not_ident_cont?(rest), do: parse_def_expr(rest), else: parse_number_or_func(input)
  end

  defp parse_primary_token("label" <> rest = input) do
    if not_ident_cont?(rest), do: parse_label_expr(rest), else: parse_number_or_func(input)
  end

  defp parse_primary_token("$" <> rest) do
    {name, rest2} = parse_identifier(rest)
    if name == "", do: throw({:parse_error, "expected variable name after $"})

    # Check for namespace access: $d::name
    rest2_trimmed = String.trim(rest2)

    if String.starts_with?(rest2_trimmed, "::") do
      rest3 = String.trim(String.slice(rest2_trimmed, 2..-1//1))
      {ns_name, rest4} = parse_identifier(rest3)

      if ns_name == "" do
        throw({:parse_error, "expected name after $#{name}::"})
      end

      {{:ns_data, name, ns_name}, rest4}
    else
      {{:var, name}, rest2}
    end
  end

  # Handle break keyword
  defp parse_primary_token("break" <> rest = input) do
    if not_ident_cont?(rest) do
      rest = String.trim(rest)
      "$" <> rest2 = rest
      {name, rest3} = parse_identifier(rest2)
      if name == "", do: throw({:parse_error, "expected variable name after break $"})
      {{:break, name}, rest3}
    else
      parse_number_or_func(input)
    end
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
    {index_expr, rest2}
  end

  # ."quoted_field"
  defp parse_dot_expr("\"" <> _ = rest) do
    {str_ast, rest2} = parse_string_literal(rest)

    key =
      case str_ast do
        {:literal, s} when is_binary(s) -> s
        _ -> throw({:parse_error, "expected simple string field name"})
      end

    {{:field, key}, rest2}
  end

  defp parse_dot_expr(rest) do
    case parse_identifier(rest) do
      {"", rest2} ->
        {:identity, rest2}

      {name, rest2} ->
        {{:field, name}, rest2}
    end
  end

  defp parse_index_expr(input) do
    input = String.trim(input)

    if String.starts_with?(input, "]") do
      {:iterate, String.slice(input, 1..-1//1)}
    else
      # Parse as a general expression and check for slice syntax
      # This handles all cases: numbers, expressions, slices, commas
      parse_bracket_contents(input)
    end
  end

  # Parse contents inside [...] brackets
  # Handles: [N], [N:M], [:M], [N:], [expr], [expr,expr,...] (comma generates multi-index)
  defp parse_bracket_contents(":" <> rest) do
    # [:M] or [:] slice — parse the end
    {end_expr, rest2} = parse_bracket_slice_end(String.trim(rest))
    rest2 = String.trim(rest2)
    "]" <> rest3 = rest2
    {{:slice_expr, {:literal, nil}, end_expr}, rest3}
  end

  defp parse_bracket_contents(input) do
    # Parse the first expression
    {expr, rest} = parse_pipe(input)
    rest = String.trim(rest)

    case rest do
      "]" <> rest2 ->
        # Simple [expr] — could be index or something
        {simplify_index_expr(expr), rest2}

      ":" <> rest2 ->
        # Slice [expr:end]
        {end_expr, rest3} = parse_bracket_slice_end(String.trim(rest2))
        rest3 = String.trim(rest3)
        "]" <> rest4 = rest3

        # Try to simplify to numeric slice
        case {to_slice_num(expr), to_slice_num(end_expr)} do
          {{:ok, s}, {:ok, e}} -> {{:slice, s, e}, rest4}
          _ -> {{:slice_expr, expr, end_expr}, rest4}
        end

      _ ->
        throw(
          {:parse_error,
           "expected ']' or ':' in bracket expression, got: #{String.slice(rest, 0..20)}"}
        )
    end
  end

  defp parse_bracket_slice_end("]" <> _ = input) do
    # Empty end: [N:]
    {{:literal, nil}, input}
  end

  defp parse_bracket_slice_end(input) do
    parse_pipe(input)
  end

  defp to_slice_num({:literal, nil}), do: {:ok, nil}
  defp to_slice_num({:literal, n}) when is_number(n), do: {:ok, n}
  defp to_slice_num(_), do: :error

  # Simplify index expression: if it's a literal number, use {:index, n}
  # If it's a literal string, use {:field, s}
  # Otherwise use {:dynamic_index, expr}
  defp simplify_index_expr({:literal, n}) when is_integer(n), do: {:index, n}
  defp simplify_index_expr({:literal, n}) when is_float(n), do: {:index, n}
  defp simplify_index_expr({:literal, s}) when is_binary(s), do: {:field, s}
  defp simplify_index_expr({:comma, _} = expr), do: {:multi_index, expr}
  defp simplify_index_expr(expr), do: {:dynamic_index, expr}

  # Build postfix indexing AST: for dynamic/multi/slice_expr indices, use
  # {:postfix_index, base, idx_expr} so the index expression is evaluated
  # against the original input (not the piped result). For static indices
  # (:index, :field, :iterate, :slice), a pipe works correctly.
  defp make_postfix_index(base, {:dynamic_index, idx_expr}) do
    {:postfix_index, base, idx_expr}
  end

  defp make_postfix_index(base, {:multi_index, idx_expr}) do
    {:postfix_multi_index, base, idx_expr}
  end

  defp make_postfix_index(base, {:slice_expr, start_expr, end_expr}) do
    {:postfix_slice_expr, base, start_expr, end_expr}
  end

  defp make_postfix_index(base, index_expr) do
    {:pipe, base, index_expr}
  end

  # parse_number removed — now using parse_scientific_or_float/1 instead

  # Check if the consumed portion had a decimal point or exponent
  defp has_decimal_or_exponent?(input, rest) do
    consumed_len = byte_size(input) - byte_size(rest)
    consumed = :binary.part(input, 0, consumed_len)

    String.contains?(consumed, ".") or String.contains?(consumed, "e") or
      String.contains?(consumed, "E")
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

      case rest do
        "]" <> rest2 -> {{:array, [expr]}, rest2}
        _ -> throw({:parse_error, "expected ']' in array construction"})
      end
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

  # Parse an object value — pipe IS consumed in object values
  # (jq -n '{x:-.|abs}' gives {x:5} with input 5)
  # But comma is NOT consumed (it separates object pairs).
  defp parse_object_value(input) do
    parse_pipe_no_comma(input)
  end

  # Like parse_pipe but does not consume top-level commas
  defp parse_pipe_no_comma(input) do
    {left, rest} = parse_or(input)
    rest = String.trim(rest)

    # Check for `as` binding
    if keyword_ahead?(rest, "as") do
      rest2 = String.trim(skip_keyword(rest, "as"))
      {pattern, rest3} = parse_as_pattern(rest2)
      rest3 = String.trim(rest3)
      {patterns, rest4} = parse_try_alt_patterns([pattern], rest3)
      "|" <> rest5 = rest4
      {body, rest6} = parse_pipe_no_comma(String.trim(rest5))
      {{:as, left, patterns, body}, rest6}
    else
      case rest do
        "|" <> rest2 ->
          {right, rest3} = parse_pipe_no_comma(String.trim(rest2))
          {{:pipe, left, right}, rest3}

        _ ->
          {left, rest}
      end
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

  # credo:disable-for-lines:80 Credo.Check.Refactor.CyclomaticComplexity
  defp parse_object_pair(input) do
    input = String.trim(input)

    case input do
      # @format key
      "@" <> _ ->
        {key, rest} = parse_format_string(String.slice(input, 1..-1//1))
        rest = String.trim(rest)

        case rest do
          ":" <> rest2 ->
            {value, rest3} = parse_object_value(String.trim(rest2))
            {{key, value}, rest3}

          _ ->
            # Shorthand: @format means @format: .@format (but that's not a thing)
            throw({:parse_error, "expected ':' after @format key in object"})
        end

      # $variable shorthand: {$x} means {"x": $x}
      "$" <> rest2 ->
        {name, rest3} = parse_identifier(rest2)
        if name == "", do: throw({:parse_error, "expected variable name"})
        rest3 = String.trim(rest3)

        case rest3 do
          ":" <> rest4 ->
            {value, rest5} = parse_object_value(String.trim(rest4))
            {{{:var, name}, value}, rest5}

          _ ->
            # Shorthand: {$x} means {x: $x}  or  {"$__loc__": $__loc__}
            {{{:literal, name}, {:var, name}}, rest3}
        end

      # Expression key: (expr):value
      "(" <> rest2 ->
        {key_expr, rest3} = parse_pipe(rest2)
        rest3 = String.trim(rest3)
        ")" <> rest4 = rest3
        rest4 = String.trim(rest4)

        case String.trim(rest4) do
          ":" <> rest5 ->
            {value, rest6} = parse_object_value(String.trim(rest5))
            {{key_expr, value}, rest6}

          _ ->
            # Shorthand (expr) means {(expr): (expr)} — using expr as both key and value
            {{key_expr, key_expr}, rest4}
        end

      # String key
      "\"" <> _ ->
        {key, rest2} = parse_string_literal(input)
        rest2 = String.trim(rest2)

        case rest2 do
          ":" <> rest3 ->
            {value, rest4} = parse_object_value(String.trim(rest3))
            {{key, value}, rest4}

          _ ->
            # Shorthand string key: {"foo"} means {"foo": .foo}
            # For interpolated strings: {"a$\(expr)"} means {("a$\(expr)"): .("a$\(expr)")}
            case key do
              {:literal, s} ->
                {{key, {:field, s}}, rest2}

              {:string_interp, _} ->
                # Use the string expression as both key and as a dynamic field lookup
                {{key, {:pipe, :identity, {:dynamic_index, key}}}, rest2}
            end
        end

      # Identifier key
      _ ->
        {name, rest2} = parse_identifier(input)
        if name == "", do: throw({:parse_error, "expected object key"})
        rest2 = String.trim(rest2)

        case rest2 do
          ":" <> rest3 ->
            {value, rest4} = parse_object_value(String.trim(rest3))
            {{{:literal, name}, value}, rest4}

          _ ->
            # Shorthand: {a} means {a: .a}
            {{{:literal, name}, {:field, name}}, rest2}
        end
    end
  end

  defp parse_parenthesized(input) do
    {expr, rest} = parse_pipe(input)
    rest = String.trim(rest)

    case rest do
      ")" <> rest2 -> {expr, rest2}
      _ -> throw({:parse_error, "expected ')'"})
    end
  end

  defp parse_string_literal("\"" <> rest) do
    {parts, rest2} = parse_string_content(rest, [])
    ast = build_string_ast(parts)
    {ast, rest2}
  end

  defp parse_string_content("\"" <> rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_string_content("\\(" <> rest, acc) do
    {expr, rest2} = parse_pipe(rest)
    rest2 = String.trim(rest2)
    ")" <> rest3 = rest2
    parse_string_content(rest3, [{:interp, expr} | acc])
  end

  defp parse_string_content("\\\"" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "\""))

  defp parse_string_content("\\n" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "\n"))

  defp parse_string_content("\\t" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "\t"))

  defp parse_string_content("\\r" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "\r"))

  defp parse_string_content("\\b" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "\b"))

  defp parse_string_content("\\f" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "\f"))

  defp parse_string_content("\\\\" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "\\"))

  defp parse_string_content("\\/" <> rest, acc),
    do: parse_string_content(rest, add_char(acc, "/"))

  defp parse_string_content("\\u" <> <<h1, h2, h3, h4, rest::binary>>, acc) do
    hex = <<h1, h2, h3, h4>>

    case Integer.parse(hex, 16) do
      {codepoint, ""} ->
        # Handle surrogate pairs
        case rest do
          "\\u" <> <<l1, l2, l3, l4, rest2::binary>>
          when codepoint >= 0xD800 and codepoint <= 0xDBFF ->
            low_hex = <<l1, l2, l3, l4>>

            case Integer.parse(low_hex, 16) do
              {low, ""} when low >= 0xDC00 and low <= 0xDFFF ->
                combined = 0x10000 + (codepoint - 0xD800) * 0x400 + (low - 0xDC00)
                parse_string_content(rest2, add_char(acc, <<combined::utf8>>))

              _ ->
                # Not a valid surrogate pair, emit replacement
                parse_string_content(rest, add_char(acc, <<0xFFFD::utf8>>))
            end

          _ ->
            if codepoint >= 0xD800 and codepoint <= 0xDFFF do
              parse_string_content(rest, add_char(acc, <<0xFFFD::utf8>>))
            else
              parse_string_content(rest, add_char(acc, <<codepoint::utf8>>))
            end
        end

      _ ->
        throw({:parse_error, "invalid unicode escape: \\u#{hex}"})
    end
  end

  # Reject invalid escape sequences (e.g., \v, \a, \x, etc.)
  defp parse_string_content("\\" <> <<c::utf8, _rest::binary>>, _acc) do
    throw({:parse_error, "Invalid escape: \\#{<<c::utf8>>}"})
  end

  defp parse_string_content(<<c::utf8, rest::binary>>, acc) do
    parse_string_content(rest, add_char(acc, <<c::utf8>>))
  end

  defp parse_string_content("", _acc) do
    throw({:parse_error, "unterminated string"})
  end

  defp add_char([{:str, s} | rest], c), do: [{:str, s <> c} | rest]
  defp add_char(acc, c), do: [{:str, c} | acc]

  defp build_string_ast([{:str, s}]), do: {:literal, s}
  defp build_string_ast([]), do: {:literal, ""}
  defp build_string_ast(parts), do: {:string_interp, parts}

  defp parse_number_or_func(input) do
    # Try to parse scientific notation that Float.parse may reject (too large/small)
    case parse_scientific_or_float(input) do
      {:ok, n, rest} ->
        if rest == "" or number_terminator?(rest) do
          {{:literal, n}, rest}
        else
          parse_identifier_or_func(input)
        end

      :error ->
        parse_identifier_or_func(input)
    end
  end

  # Parse a number, handling scientific notation that may overflow/underflow
  defp parse_scientific_or_float(input) do
    case Float.parse(input) do
      {n, rest} ->
        n = if n == trunc(n) and not has_decimal_or_exponent?(input, rest), do: trunc(n), else: n
        {:ok, n, rest}

      :error ->
        # Float.parse failed — try to match scientific notation pattern manually
        # e.g., 5E500000000 or 1E-999999999
        case Regex.run(~r/^(\d+(?:\.\d+)?)[eE]([+-]?\d+)(.*)$/s, input) do
          [_, _mantissa, exponent_str, rest] ->
            {exp, ""} = Integer.parse(exponent_str)

            n =
              cond do
                # infinity-ish
                exp > 300 -> 1.7_976_931_348_623_157e308
                exp < -300 -> 0.0
                # shouldn't happen if Float.parse worked
                true -> 0.0
              end

            {:ok, n, rest}

          nil ->
            :error
        end
    end
  end

  @number_terminators [?\s, ?\t, ?\n, ?\r, ?), ?], ?[, ?,, ?}, ?|, ?;, ?:]

  defp number_terminator?(<<c, _::binary>>) when c in @number_terminators, do: true
  # Also treat +, -, *, /, %, <, >, =, ! as terminators so 1+1 parses
  defp number_terminator?(<<c, _::binary>>) when c in [?+, ?-, ?*, ?/, ?%, ?<, ?>, ?=, ?!],
    do: true

  defp number_terminator?(_), do: false

  defp parse_identifier_or_func(input) do
    case parse_identifier(input) do
      {"", _} ->
        throw({:parse_error, "unexpected input: #{String.slice(input, 0..20)}"})

      {name, rest} ->
        rest = String.trim(rest)

        # Check for namespace access: foo::bar
        if String.starts_with?(rest, "::") do
          rest2 = String.trim(String.slice(rest, 2..-1//1))
          {func_name, rest3} = parse_identifier(rest2)

          if func_name == "" do
            throw({:parse_error, "expected function name after ::"})
          end

          rest3 = String.trim(rest3)

          if String.starts_with?(rest3, "(") do
            {args, rest4} = parse_func_args(String.slice(rest3, 1..-1//1))
            {{:ns_func, name, safe_to_atom(func_name), args}, rest4}
          else
            {{:ns_func, name, safe_to_atom(func_name), []}, rest3}
          end
        else
          if String.starts_with?(rest, "(") do
            {args, rest3} = parse_func_args(String.slice(rest, 1..-1//1))
            {{:func, safe_to_atom(name), args}, rest3}
          else
            {{:func, safe_to_atom(name), []}, rest}
          end
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

  defp parse_func_args_tail(_acc, rest) do
    throw(
      {:parse_error, "expected ')' or ';' in function args, got: #{String.slice(rest, 0..20)}"}
    )
  end

  defp parse_if_expr(rest) do
    rest = String.trim(rest)
    {cond_expr, rest2} = parse_pipe(rest)
    rest2 = String.trim(rest2)

    if keyword_ahead?(rest2, "then") do
      rest3 = skip_keyword(rest2, "then")
      {then_expr, rest4} = parse_pipe(String.trim(rest3))
      rest4 = String.trim(rest4)
      parse_if_else(cond_expr, then_expr, rest4)
    else
      throw({:parse_error, "expected 'then' in if expression"})
    end
  end

  defp parse_if_else(cond_expr, then_expr, rest) do
    cond do
      keyword_ahead?(rest, "elif") ->
        rest2 = skip_keyword(rest, "elif")
        rest2 = String.trim(rest2)
        {elif_cond, rest3} = parse_pipe(rest2)
        rest3 = String.trim(rest3)

        if keyword_ahead?(rest3, "then") do
          rest4 = skip_keyword(rest3, "then")
          {elif_then, rest5} = parse_pipe(String.trim(rest4))
          rest5 = String.trim(rest5)
          {else_expr, rest6} = parse_if_else(elif_cond, elif_then, rest5)
          {{:if, cond_expr, then_expr, else_expr}, rest6}
        else
          throw({:parse_error, "expected 'then' after elif condition"})
        end

      keyword_ahead?(rest, "else") ->
        rest2 = skip_keyword(rest, "else")
        {else_expr, rest3} = parse_pipe(String.trim(rest2))
        rest3 = String.trim(rest3)

        if keyword_ahead?(rest3, "end") do
          rest4 = skip_keyword(rest3, "end")
          {{:if, cond_expr, then_expr, else_expr}, rest4}
        else
          throw({:parse_error, "expected 'end' after else"})
        end

      keyword_ahead?(rest, "end") ->
        rest2 = skip_keyword(rest, "end")
        {{:if, cond_expr, then_expr, :identity}, rest2}

      true ->
        throw(
          {:parse_error,
           "expected 'elif', 'else', or 'end' in if expression, got: #{String.slice(rest, 0..20)}"}
        )
    end
  end

  defp parse_try_expr(rest) do
    {expr, rest2} = parse_try_body(String.trim(rest))
    rest2 = String.trim(rest2)

    # Check for optional catch clause
    if keyword_ahead?(rest2, "catch") do
      rest3 = String.trim(skip_keyword(rest2, "catch"))
      {catch_expr, rest4} = parse_try_body(rest3)
      {{:try, expr, catch_expr}, rest4}
    else
      {{:try, expr, nil}, rest2}
    end
  end

  # Parse the body of try or catch — handles unary minus and postfix chains
  defp parse_try_body("-" <> _ = input) do
    parse_unary(input)
  end

  defp parse_try_body(input) do
    parse_postfix(parse_primary(input))
  end

  # Known jq format names — ensure these atoms exist for safe_to_atom
  @known_formats ~w(csv tsv json text base64 base64d uri urid sh html)a

  defp parse_format_string(input) do
    # Reference @known_formats to ensure atoms are compiled
    _ = @known_formats

    case parse_identifier(input) do
      {"", _} ->
        throw({:parse_error, "expected format name after @"})

      {name, rest} ->
        rest = String.trim(rest)

        # Check for @format "string interpolation"
        case rest do
          "\"" <> _ ->
            {str_ast, rest2} = parse_string_literal(rest)
            {{:format_str, safe_to_atom(name), str_ast}, rest2}

          _ ->
            {{:format, safe_to_atom(name)}, rest}
        end
    end
  end

  # def NAME: BODY; REST  or  def NAME(PARAMS): BODY; REST
  defp parse_def_expr(rest) do
    rest = String.trim(rest)
    {name, rest2} = parse_identifier(rest)
    if name == "", do: throw({:parse_error, "expected function name after def"})
    rest2 = String.trim(rest2)

    # Parse optional parameters
    {params, rest3} =
      case rest2 do
        "(" <> rest3 -> parse_def_params(String.trim(rest3))
        _ -> {[], rest2}
      end

    # Expect ":"
    rest3 = String.trim(rest3)

    case rest3 do
      ":" <> rest4 ->
        {body, rest5} = parse_pipe(String.trim(rest4))
        rest5 = String.trim(rest5)

        case rest5 do
          ";" <> rest6 ->
            # Parse the expression after the definition (rest of program)
            {after_def, rest7} = parse_pipe(String.trim(rest6))
            {{:def, name, params, body, after_def}, rest7}

          _ ->
            throw({:parse_error, "expected ';' after def body"})
        end

      _ ->
        throw({:parse_error, "expected ':' after def name/params"})
    end
  end

  defp parse_def_params(input) do
    input = String.trim(input)

    case input do
      ")" <> rest ->
        {[], rest}

      _ ->
        {param, rest} = parse_def_param(input)
        rest = String.trim(rest)
        parse_def_params_tail([param], rest)
    end
  end

  defp parse_def_params_tail(acc, ")" <> rest), do: {Enum.reverse(acc), rest}

  defp parse_def_params_tail(acc, ";" <> rest) do
    {param, rest2} = parse_def_param(String.trim(rest))
    parse_def_params_tail([param | acc], String.trim(rest2))
  end

  defp parse_def_params_tail(_acc, rest) do
    throw({:parse_error, "expected ')' or ';' in def params, got: #{String.slice(rest, 0..20)}"})
  end

  # A def parameter can be a name (filter arg) or $name (value arg)
  defp parse_def_param("$" <> rest) do
    {name, rest2} = parse_identifier(rest)
    if name == "", do: throw({:parse_error, "expected parameter name after $"})
    {{:value_param, name}, rest2}
  end

  defp parse_def_param(input) do
    {name, rest} = parse_identifier(input)
    if name == "", do: throw({:parse_error, "expected parameter name in def"})
    {{:filter_param, name}, rest}
  end

  # label $NAME | BODY
  defp parse_label_expr(rest) do
    rest = String.trim(rest)
    "$" <> rest2 = rest
    {name, rest3} = parse_identifier(rest2)
    if name == "", do: throw({:parse_error, "expected variable name after label $"})
    rest3 = String.trim(rest3)
    "|" <> rest4 = rest3
    {body, rest5} = parse_pipe(String.trim(rest4))
    {{:label, name, body}, rest5}
  end

  # reduce EXPR as PATTERN (INIT; UPDATE)
  defp parse_reduce_expr(rest) do
    rest = String.trim(rest)
    {expr, rest2} = parse_expr_before_as(rest)
    rest2 = String.trim(rest2)

    if keyword_ahead?(rest2, "as") do
      rest3 = String.trim(skip_keyword(rest2, "as"))
      {pattern, rest4} = parse_as_pattern(rest3)
      rest4 = String.trim(rest4)
      "(" <> rest5 = rest4
      {init, rest6} = parse_pipe(String.trim(rest5))
      rest6 = String.trim(rest6)
      ";" <> rest7 = rest6
      {update, rest8} = parse_pipe(String.trim(rest7))
      rest8 = String.trim(rest8)
      ")" <> rest9 = rest8
      {{:reduce, expr, pattern, init, update}, rest9}
    else
      throw({:parse_error, "expected 'as' in reduce expression"})
    end
  end

  # foreach EXPR as PATTERN (INIT; UPDATE [; EXTRACT])
  defp parse_foreach_expr(rest) do
    rest = String.trim(rest)
    {expr, rest2} = parse_expr_before_as(rest)
    rest2 = String.trim(rest2)

    if keyword_ahead?(rest2, "as") do
      rest3 = String.trim(skip_keyword(rest2, "as"))
      {pattern, rest4} = parse_as_pattern(rest3)
      rest4 = String.trim(rest4)
      "(" <> rest5 = rest4
      {init, rest6} = parse_pipe(String.trim(rest5))
      rest6 = String.trim(rest6)
      ";" <> rest7 = rest6
      {update, rest8} = parse_pipe(String.trim(rest7))
      rest8 = String.trim(rest8)

      case rest8 do
        ";" <> rest9 ->
          {extract, rest10} = parse_pipe(String.trim(rest9))
          rest10 = String.trim(rest10)
          ")" <> rest11 = rest10
          {{:foreach, expr, pattern, init, update, extract}, rest11}

        ")" <> rest9 ->
          {{:foreach, expr, pattern, init, update, :identity}, rest9}
      end
    else
      throw({:parse_error, "expected 'as' in foreach expression"})
    end
  end

  # Parse an expression that appears before `as` in reduce/foreach
  # This is like parse_multiplicative (handles *, /, +, -, unary) but stops before `as`
  defp parse_expr_before_as(input) do
    # Parse up to (but not including) the `as` keyword
    # We need to handle expressions like .[] / .[] or -.[] etc.
    parse_multiplicative(input)
  end

  # Keyword-matching helpers
  defp keyword_ahead?(input, keyword) do
    kw_len = byte_size(keyword)

    byte_size(input) >= kw_len and
      :binary.part(input, 0, kw_len) == keyword and
      not_ident_cont?(
        if byte_size(input) > kw_len,
          do: :binary.part(input, kw_len, byte_size(input) - kw_len),
          else: ""
      )
  end

  defp skip_keyword(input, keyword) do
    kw_len = byte_size(keyword)
    :binary.part(input, kw_len, byte_size(input) - kw_len)
  end

  # Convert function name strings to atoms safely.
  # Built-in jq function names already exist as atoms (defined in Functions module).
  # User-defined function names may not, so we keep them as strings to avoid
  # atom table exhaustion from adversarial input.
  defp safe_to_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end
end
