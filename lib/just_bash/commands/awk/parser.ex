defmodule JustBash.Commands.Awk.Parser do
  @moduledoc """
  Parser for AWK programs.

  Parses AWK program strings into an AST representation that can be
  executed by the Evaluator.
  """

  @type pattern :: nil | {:regex, String.t()} | {:condition, String.t()}
  @type expr ::
          {:literal, String.t()}
          | {:number, number()}
          | {:field, non_neg_integer()}
          | {:field_var, String.t()}
          | {:variable, String.t()}
          | {:add, expr(), expr()}
  @type statement ::
          {:print, [expr()]}
          | {:printf, {String.t(), [expr()]}}
          | {:assign, String.t(), expr()}
          | {:add_assign, String.t(), expr()}
          | {:increment, String.t()}
          | nil
  @type rule :: {pattern(), [statement()]}
  @type program :: %{
          begin_blocks: [[statement()]],
          end_blocks: [[statement()]],
          main_rules: [rule()]
        }

  @doc """
  Parse an AWK program string into an AST.

  Returns `{:ok, program}` on success or `{:error, message}` on failure.
  """
  @spec parse(String.t()) :: {:ok, program()} | {:error, String.t()}
  def parse(program_str) do
    rules = parse_rules(program_str)
    {:ok, rules}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_rules(program) do
    program = String.trim(program)

    {begin_blocks, rest} = extract_blocks(program, "BEGIN")
    {end_blocks, rest} = extract_blocks(rest, "END")
    main_rules = parse_main_rules(rest)

    %{
      begin_blocks: begin_blocks,
      end_blocks: end_blocks,
      main_rules: main_rules
    }
  end

  defp extract_blocks(program, block_type) do
    extract_blocks_loop(program, block_type, [])
  end

  defp extract_blocks_loop(program, block_type, acc) do
    pattern = ~r/#{block_type}\s*\{/

    case Regex.run(pattern, program, return: :index) do
      [{start, len}] ->
        brace_start = start + len - 1

        case find_matching_brace(program, brace_start) do
          {:ok, brace_end} ->
            action = String.slice(program, (brace_start + 1)..(brace_end - 1)//1)
            before = String.slice(program, 0, start)
            after_block = String.slice(program, (brace_end + 1)..-1//1)
            rest = before <> after_block
            extract_blocks_loop(rest, block_type, [parse_action(action) | acc])

          :error ->
            {Enum.reverse(acc), program}
        end

      nil ->
        {Enum.reverse(acc), program}
    end
  end

  defp find_matching_brace(str, start) do
    find_matching_brace(str, start + 1, 1)
  end

  defp find_matching_brace(_str, _pos, 0), do: :error

  defp find_matching_brace(str, pos, _depth) when pos >= byte_size(str), do: :error

  defp find_matching_brace(str, pos, depth) do
    char = String.at(str, pos)

    cond do
      char == "{" -> find_matching_brace(str, pos + 1, depth + 1)
      char == "}" and depth == 1 -> {:ok, pos}
      char == "}" -> find_matching_brace(str, pos + 1, depth - 1)
      char == "\"" -> skip_string(str, pos + 1, ?") |> then(&find_matching_brace(str, &1, depth))
      char == "'" -> skip_string(str, pos + 1, ?') |> then(&find_matching_brace(str, &1, depth))
      true -> find_matching_brace(str, pos + 1, depth)
    end
  end

  defp skip_string(str, pos, _quote_char) when pos >= byte_size(str), do: pos

  defp skip_string(str, pos, quote_char) do
    char = :binary.at(str, pos)

    cond do
      char == ?\\ and pos + 1 < byte_size(str) -> skip_string(str, pos + 2, quote_char)
      char == quote_char -> pos + 1
      true -> skip_string(str, pos + 1, quote_char)
    end
  end

  defp parse_main_rules(""), do: []

  defp parse_main_rules(program) do
    program = String.trim(program)

    cond do
      String.starts_with?(program, "{") ->
        parse_bare_action_rule(program)

      String.starts_with?(program, "/") ->
        parse_main_regex_rule(program)

      true ->
        parse_main_pattern_rule(program)
    end
  end

  defp parse_bare_action_rule(program) do
    case extract_action(program) do
      {:ok, action, rest} ->
        [{nil, parse_action(action)} | parse_main_rules(rest)]

      :error ->
        []
    end
  end

  defp parse_main_regex_rule(program) do
    case parse_regex_rule(program) do
      {:ok, pattern, action, rest} ->
        action = if action == "", do: "print", else: action
        [{{:regex, pattern}, parse_action(action)} | parse_main_rules(rest)]

      :error ->
        []
    end
  end

  defp parse_main_pattern_rule(program) do
    case parse_pattern_rule(program) do
      {:ok, pattern, action, rest} ->
        [{parse_pattern(pattern), parse_action(action)} | parse_main_rules(rest)]

      :error ->
        parse_main_fallback_rule(program)
    end
  end

  defp parse_main_fallback_rule(program) do
    case extract_action_new(program) do
      {:ok, action, rest} ->
        [{nil, parse_action(action)} | parse_main_rules(rest)]

      :error ->
        []
    end
  end

  defp parse_pattern_rule(program) do
    case Regex.run(~r/^([^{]+)\s*\{/, program, return: :index) do
      [{0, _}, {pat_start, pat_len}] ->
        pattern = String.slice(program, pat_start, pat_len) |> String.trim()
        rest = Regex.replace(~r/^[^{]+\s*/, program, "")

        case extract_action_new(rest) do
          {:ok, action, remaining} ->
            {:ok, pattern, action, remaining}

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp extract_action(program) do
    extract_action_new(program)
  end

  defp extract_action_new(program) do
    if String.starts_with?(program, "{") do
      case find_matching_brace(program, 0) do
        {:ok, end_pos} ->
          action = String.slice(program, 1..(end_pos - 1)//1)
          rest = String.slice(program, (end_pos + 1)..-1//1) |> String.trim()
          {:ok, action, rest}

        :error ->
          :error
      end
    else
      :error
    end
  end

  defp parse_regex_rule(program) do
    case Regex.run(~r|^/([^/]*)/\s*|, program) do
      [match, pattern] ->
        rest = String.slice(program, String.length(match)..-1//1)

        case extract_action(rest) do
          {:ok, action, remaining} ->
            {:ok, pattern, action, remaining}

          :error ->
            {:ok, pattern, "", rest}
        end

      nil ->
        :error
    end
  end

  defp parse_pattern(pattern) do
    pattern = String.trim(pattern)

    cond do
      pattern =~ ~r/^NR\s*[=<>!]+\s*\d+$/ ->
        {:condition, pattern}

      pattern =~ ~r/^\$\d+\s*[=<>!~]+/ ->
        {:condition, pattern}

      pattern =~ ~r/^\/.*\/$/ ->
        regex_pattern = String.slice(pattern, 1..-2//1)
        {:regex, regex_pattern}

      true ->
        {:condition, pattern}
    end
  end

  defp parse_action(action) do
    action = String.trim(action)
    parse_statements(action)
  end

  defp parse_statements(action) do
    action
    |> split_statements()
    |> Enum.map(&parse_statement/1)
    |> Enum.filter(&(&1 != nil))
  end

  defp split_statements(action) do
    action
    |> String.split(~r/[;\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> merge_if_else()
  end

  # Merge "if ..." and "else ..." back together
  defp merge_if_else([]), do: []

  defp merge_if_else([if_stmt, else_stmt | rest])
       when is_binary(if_stmt) and is_binary(else_stmt) do
    if String.starts_with?(if_stmt, "if") and String.starts_with?(else_stmt, "else") do
      merged = if_stmt <> "; " <> else_stmt
      merge_if_else([merged | rest])
    else
      [if_stmt | merge_if_else([else_stmt | rest])]
    end
  end

  defp merge_if_else([stmt | rest]), do: [stmt | merge_if_else(rest)]

  defp parse_statement(stmt) do
    cond do
      String.starts_with?(stmt, "if ") or String.starts_with?(stmt, "if(") ->
        parse_if_statement(stmt)

      String.starts_with?(stmt, "print ") or stmt == "print" ->
        parse_print_statement(stmt)

      String.starts_with?(stmt, "printf ") ->
        parse_printf_statement(stmt)

      String.starts_with?(stmt, "gsub(") ->
        parse_gsub_statement(stmt, :gsub)

      String.starts_with?(stmt, "sub(") ->
        parse_gsub_statement(stmt, :sub)

      stmt =~ ~r/^\w+\s*=/ ->
        parse_assign_statement(stmt)

      stmt =~ ~r/^\w+\s*\+=/ ->
        parse_add_assign_statement(stmt)

      stmt =~ ~r/^\w+\+\+$/ ->
        parse_increment_statement(stmt)

      true ->
        nil
    end
  end

  defp parse_print_statement(stmt) do
    args = String.trim_leading(stmt, "print") |> String.trim()

    if args == "" do
      {:print, [{:field, 0}]}
    else
      {:print, parse_print_args(args)}
    end
  end

  defp parse_printf_statement(stmt) do
    args = String.trim_leading(stmt, "printf") |> String.trim()
    {:printf, parse_printf_args(args)}
  end

  defp parse_assign_statement(stmt) do
    case Regex.run(~r/^(\w+)\s*=\s*(.+)$/, stmt) do
      [_, var, expr] -> {:assign, var, parse_expression(expr)}
      nil -> nil
    end
  end

  defp parse_add_assign_statement(stmt) do
    case Regex.run(~r/^(\w+)\s*\+=\s*(.+)$/, stmt) do
      [_, var, expr] -> {:add_assign, var, parse_expression(expr)}
      nil -> nil
    end
  end

  defp parse_increment_statement(stmt) do
    case Regex.run(~r/^(\w+)\+\+$/, stmt) do
      [_, var] -> {:increment, var}
      nil -> nil
    end
  end

  # Parse if (condition) action; else action
  defp parse_if_statement(stmt) do
    # Match: if (condition) then_stmt; else else_stmt
    # or: if (condition) then_stmt
    stmt = String.trim_leading(stmt, "if")

    case extract_condition_and_body(stmt) do
      {:ok, condition, body} ->
        # Check for else clause
        case String.split(body, ~r/;\s*else\s+/, parts: 2) do
          [then_part, else_part] ->
            then_stmt = parse_statement(String.trim(then_part))
            else_stmt = parse_statement(String.trim(else_part))
            {:if, parse_condition_expr(condition), then_stmt, else_stmt}

          [then_part] ->
            then_stmt = parse_statement(String.trim(then_part))
            {:if, parse_condition_expr(condition), then_stmt, nil}
        end

      :error ->
        nil
    end
  end

  defp extract_condition_and_body(stmt) do
    stmt = String.trim(stmt)

    if String.starts_with?(stmt, "(") do
      case find_matching_paren(stmt, 0) do
        {:ok, end_pos} ->
          condition = String.slice(stmt, 1..(end_pos - 1)//1)
          body = String.slice(stmt, (end_pos + 1)..-1//1) |> String.trim()
          {:ok, condition, body}

        :error ->
          :error
      end
    else
      :error
    end
  end

  defp find_matching_paren(str, start) do
    find_matching_paren_loop(str, start + 1, 1)
  end

  defp find_matching_paren_loop(_str, _pos, 0), do: :error

  defp find_matching_paren_loop(str, pos, _depth) when pos >= byte_size(str), do: :error

  defp find_matching_paren_loop(str, pos, depth) do
    char = String.at(str, pos)

    cond do
      char == "(" -> find_matching_paren_loop(str, pos + 1, depth + 1)
      char == ")" and depth == 1 -> {:ok, pos}
      char == ")" -> find_matching_paren_loop(str, pos + 1, depth - 1)
      true -> find_matching_paren_loop(str, pos + 1, depth)
    end
  end

  # Parse condition expressions like $1 > 3 or NR == 1
  defp parse_condition_expr(condition) do
    condition = String.trim(condition)

    cond do
      # Numeric comparisons: $1 > 3, NR == 1, etc.
      match = Regex.run(~r/^(.+?)\s*(==|!=|>=|<=|>|<)\s*(.+)$/, condition) ->
        [_, left, op, right] = match
        {String.to_atom(op), parse_expression(left), parse_expression(right)}

      # Regex match: $1 ~ /pattern/
      match = Regex.run(~r/^(.+?)\s*~\s*\/(.+)\/$/, condition) ->
        [_, expr, pattern] = match
        {:match, parse_expression(expr), pattern}

      true ->
        # Default: treat as truthy expression
        {:truthy, parse_expression(condition)}
    end
  end

  # Parse gsub(/pattern/, "replacement") or gsub(/pattern/, "replacement", target)
  defp parse_gsub_statement(stmt, type) do
    # Match: gsub(/pattern/, "replacement") or sub(/pattern/, "replacement")
    case Regex.run(~r/^(?:g?sub)\(\/([^\/]*)\/,\s*"([^"]*)"(?:,\s*(\$\d+))?\)$/, stmt) do
      [_, pattern, replacement, target] when target != "" ->
        {type, pattern, replacement, parse_expression(target)}

      [_, pattern, replacement] ->
        {type, pattern, replacement, {:field, 0}}

      [_, pattern, replacement, _] ->
        {type, pattern, replacement, {:field, 0}}

      nil ->
        nil
    end
  end

  defp parse_print_args(args) do
    cond do
      # Ternary expression
      ternary_pattern?(args) ->
        [parse_expression(args)]

      # Single function call (contains parens with balanced content)
      function_call_pattern?(args) ->
        [parse_expression(args)]

      # Single expression (possibly arithmetic)
      arithmetic_pattern?(args) ->
        [parse_expression(args)]

      # Comma-separated arguments (but not inside function calls)
      String.contains?(args, ",") and not String.contains?(args, "(") ->
        args
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&parse_expression/1)

      # Space-separated fields/values (traditional awk: print $1 $2)
      true ->
        args
        |> String.split(~r/\s+/)
        |> Enum.map(&parse_expression/1)
    end
  end

  defp parse_printf_args(args) do
    case Regex.run(~r/^"([^"]*)"(?:,\s*(.*))?$/, args) do
      [_, format, rest] when rest != "" ->
        rest_args =
          rest
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&parse_expression/1)

        {format, rest_args}

      [_, format, _] ->
        {format, []}

      [_, format] ->
        {format, []}

      nil ->
        {args, []}
    end
  end

  @doc """
  Parse an expression string into an expression AST.
  """
  @spec parse_expression(String.t()) :: expr()
  def parse_expression(expr) do
    expr = String.trim(expr)
    dispatch_expression(expr)
  end

  defp dispatch_expression(""), do: {:literal, ""}

  defp dispatch_expression(expr) do
    cond do
      quoted_string?(expr) -> parse_string_literal(expr)
      # Check for ternary operator
      ternary_pattern?(expr) -> parse_ternary(expr)
      # Check for function calls: name(args)
      function_call_pattern?(expr) -> parse_function_call(expr)
      # Check for arithmetic BEFORE simple field/variable parsing
      arithmetic_pattern?(expr) -> parse_arithmetic(expr)
      String.starts_with?(expr, "$") -> parse_field_expression(expr)
      number_pattern?(expr) -> parse_number_literal(expr)
      word_pattern?(expr) -> {:variable, expr}
      true -> {:literal, expr}
    end
  end

  defp quoted_string?(s), do: String.starts_with?(s, "\"") and String.ends_with?(s, "\"")
  defp number_pattern?(s), do: s =~ ~r/^\d+(\.\d+)?$/
  defp word_pattern?(s), do: s =~ ~r/^\w+$/
  # Match function calls: name(args)
  defp function_call_pattern?(s), do: s =~ ~r/^\w+\([^)]*\)$/
  # Match ternary operator: expr ? val1 : val2
  defp ternary_pattern?(s), do: s =~ ~r/\?\s*[^:]+\s*:/
  # Match expressions containing arithmetic operators: + - * /
  defp arithmetic_pattern?(s), do: s =~ ~r/[\+\-\*\/]/ and not quoted_string?(s)

  defp parse_string_literal(expr) do
    {:literal, String.slice(expr, 1..-2//1) |> unescape_string()}
  end

  defp parse_field_expression(expr) do
    field_str = String.slice(expr, 1..-1//1)

    case Integer.parse(field_str) do
      {n, ""} -> {:field, n}
      _ -> {:field_var, field_str}
    end
  end

  defp parse_number_literal(expr) do
    {n, _} = Float.parse(expr)
    {:number, n}
  end

  # Parse ternary operator: condition ? true_val : false_val
  defp parse_ternary(expr) do
    # Handle parenthesized condition: (condition) ? true : false
    if String.starts_with?(expr, "(") do
      case find_matching_paren(expr, 0) do
        {:ok, end_pos} ->
          condition = String.slice(expr, 1..(end_pos - 1)//1)
          rest = String.slice(expr, (end_pos + 1)..-1//1) |> String.trim()

          case Regex.run(~r/^\?\s*(.+?)\s*:\s*(.+)$/, rest) do
            [_, true_val, false_val] ->
              {:ternary, parse_condition_expr(String.trim(condition)),
               parse_expression(String.trim(true_val)), parse_expression(String.trim(false_val))}

            nil ->
              {:literal, expr}
          end

        :error ->
          {:literal, expr}
      end
    else
      # Non-parenthesized condition
      case Regex.run(~r/^(.+?)\s*\?\s*(.+?)\s*:\s*(.+)$/, expr) do
        [_, condition, true_val, false_val] ->
          {:ternary, parse_condition_expr(String.trim(condition)),
           parse_expression(String.trim(true_val)), parse_expression(String.trim(false_val))}

        nil ->
          {:literal, expr}
      end
    end
  end

  # Parse function calls: name(arg1, arg2, ...)
  defp parse_function_call(expr) do
    case Regex.run(~r/^(\w+)\(([^)]*)\)$/, expr) do
      [_, name, args_str] ->
        args =
          if String.trim(args_str) == "" do
            []
          else
            args_str
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.map(&parse_expression/1)
          end

        {:call, name, args}

      nil ->
        {:literal, expr}
    end
  end

  # Parse arithmetic expressions with proper operator precedence
  # Handles: +, -, *, /
  defp parse_arithmetic(expr) do
    # Try operators in order of precedence (lowest first, so they bind loosest)
    # Addition/subtraction first (lowest precedence)
    cond do
      match = Regex.run(~r/^(.+)\s*\+\s*([^\+\-]+)$/, expr) ->
        [_, left, right] = match
        {:add, parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+)\s*\-\s*([^\+\-]+)$/, expr) ->
        [_, left, right] = match
        {:sub, parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+)\s*\*\s*([^\*\/]+)$/, expr) ->
        [_, left, right] = match
        {:mul, parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+)\s*\/\s*([^\*\/]+)$/, expr) ->
        [_, left, right] = match
        {:div, parse_expression(left), parse_expression(right)}

      true ->
        {:literal, expr}
    end
  end

  @doc """
  Unescape common escape sequences in a string.
  """
  @spec unescape_string(String.t()) :: String.t()
  def unescape_string(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end
end
