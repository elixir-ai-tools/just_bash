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
    |> split_respecting_quotes()
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> merge_if_else()
  end

  # Split on ; and \n but respect quoted strings, braces, and parentheses
  defp split_respecting_quotes(str) do
    # State: {current, acc, in_string, brace_depth, paren_depth}
    split_respecting_quotes(str, "", [], false, 0, 0)
  end

  defp split_respecting_quotes("", current, acc, _in_string, _brace_depth, _paren_depth) do
    Enum.reverse([current | acc])
  end

  defp split_respecting_quotes(
         <<"\\", char::utf8, rest::binary>>,
         current,
         acc,
         in_string,
         brace_depth,
         paren_depth
       ) do
    # Escaped character - keep it
    split_respecting_quotes(
      rest,
      current <> "\\" <> <<char::utf8>>,
      acc,
      in_string,
      brace_depth,
      paren_depth
    )
  end

  defp split_respecting_quotes(
         <<"\"", rest::binary>>,
         current,
         acc,
         in_string,
         brace_depth,
         paren_depth
       ) do
    # Toggle quote mode
    split_respecting_quotes(rest, current <> "\"", acc, not in_string, brace_depth, paren_depth)
  end

  defp split_respecting_quotes(
         <<"{", rest::binary>>,
         current,
         acc,
         false,
         brace_depth,
         paren_depth
       ) do
    # Opening brace outside quotes - increase brace depth
    split_respecting_quotes(rest, current <> "{", acc, false, brace_depth + 1, paren_depth)
  end

  defp split_respecting_quotes(
         <<"}", rest::binary>>,
         current,
         acc,
         false,
         brace_depth,
         paren_depth
       )
       when brace_depth > 0 do
    # Closing brace outside quotes - decrease brace depth
    split_respecting_quotes(rest, current <> "}", acc, false, brace_depth - 1, paren_depth)
  end

  defp split_respecting_quotes(
         <<"(", rest::binary>>,
         current,
         acc,
         false,
         brace_depth,
         paren_depth
       ) do
    # Opening paren outside quotes - increase paren depth
    split_respecting_quotes(rest, current <> "(", acc, false, brace_depth, paren_depth + 1)
  end

  defp split_respecting_quotes(
         <<")", rest::binary>>,
         current,
         acc,
         false,
         brace_depth,
         paren_depth
       )
       when paren_depth > 0 do
    # Closing paren outside quotes - decrease paren depth
    split_respecting_quotes(rest, current <> ")", acc, false, brace_depth, paren_depth - 1)
  end

  defp split_respecting_quotes(<<char::utf8, rest::binary>>, current, acc, false, 0, 0)
       when char == ?; or char == ?\n do
    # Statement separator outside quotes, braces, and parens
    split_respecting_quotes(rest, "", [current | acc], false, 0, 0)
  end

  defp split_respecting_quotes(
         <<char::utf8, rest::binary>>,
         current,
         acc,
         in_string,
         brace_depth,
         paren_depth
       ) do
    split_respecting_quotes(
      rest,
      current <> <<char::utf8>>,
      acc,
      in_string,
      brace_depth,
      paren_depth
    )
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
      String.starts_with?(stmt, "for ") or String.starts_with?(stmt, "for(") ->
        parse_for_statement(stmt)

      String.starts_with?(stmt, "while ") or String.starts_with?(stmt, "while(") ->
        parse_while_statement(stmt)

      String.starts_with?(stmt, "do ") or String.starts_with?(stmt, "do{") ->
        parse_do_while_statement(stmt)

      String.starts_with?(stmt, "if ") or String.starts_with?(stmt, "if(") ->
        parse_if_statement(stmt)

      stmt == "break" ->
        {:break}

      stmt == "continue" ->
        {:continue}

      stmt == "next" ->
        {:next}

      String.starts_with?(stmt, "exit") ->
        parse_exit_statement(stmt)

      String.starts_with?(stmt, "print ") or stmt == "print" ->
        parse_print_statement(stmt)

      String.starts_with?(stmt, "printf ") ->
        parse_printf_statement(stmt)

      String.starts_with?(stmt, "gsub(") ->
        parse_gsub_statement(stmt, :gsub)

      String.starts_with?(stmt, "sub(") ->
        parse_gsub_statement(stmt, :sub)

      String.starts_with?(stmt, "delete ") ->
        parse_delete_statement(stmt)

      # Array assignment: arr[key] = value
      stmt =~ ~r/^\w+\[.+\]\s*=/ ->
        parse_array_assign_statement(stmt)

      # Array increment: arr[key]++
      stmt =~ ~r/^\w+\[.+\]\+\+$/ ->
        parse_array_increment_statement(stmt)

      # Array compound assignment: arr[key] += value
      stmt =~ ~r/^\w+\[.+\]\s*\+=/ ->
        parse_array_add_assign_statement(stmt)

      stmt =~ ~r/^\w+\s*=/ ->
        parse_assign_statement(stmt)

      stmt =~ ~r/^\w+\s*\+=/ ->
        parse_add_assign_statement(stmt)

      stmt =~ ~r/^\w+\s*\-=/ ->
        parse_sub_assign_statement(stmt)

      stmt =~ ~r/^\w+\s*\*=/ ->
        parse_mul_assign_statement(stmt)

      stmt =~ ~r/^\w+\s*\/=/ ->
        parse_div_assign_statement(stmt)

      stmt =~ ~r/^\w+\+\+$/ ->
        parse_increment_statement(stmt)

      stmt =~ ~r/^\+\+\w+$/ ->
        parse_pre_increment_statement(stmt)

      stmt =~ ~r/^\w+\-\-$/ ->
        parse_decrement_statement(stmt)

      stmt =~ ~r/^\-\-\w+$/ ->
        parse_pre_decrement_statement(stmt)

      true ->
        nil
    end
  end

  # Parse for loop: for (init; cond; update) body
  defp parse_for_statement(stmt) do
    stmt = String.trim_leading(stmt, "for") |> String.trim()

    case extract_condition_and_body(stmt) do
      {:ok, loop_spec, body} ->
        # Check if it's for-in: for (var in array)
        if String.contains?(loop_spec, " in ") do
          parse_for_in_loop(loop_spec, body)
        else
          parse_c_style_for(loop_spec, body)
        end

      :error ->
        nil
    end
  end

  defp parse_for_in_loop(loop_spec, body) do
    case Regex.run(~r/^\s*(\w+)\s+in\s+(\w+)\s*$/, loop_spec) do
      [_, var, array] ->
        body_stmts = parse_loop_body(body)
        {:for_in, var, array, body_stmts}

      nil ->
        nil
    end
  end

  defp parse_c_style_for(loop_spec, body) do
    parts = String.split(loop_spec, ";")

    if length(parts) == 3 do
      [init_str, cond_str, update_str] = Enum.map(parts, &String.trim/1)
      init = if init_str == "", do: nil, else: parse_statement(init_str)
      cond_expr = if cond_str == "", do: {:number, 1}, else: parse_expression(cond_str)
      update = if update_str == "", do: nil, else: parse_statement(update_str)
      body_stmts = parse_loop_body(body)
      {:for, init, cond_expr, update, body_stmts}
    else
      nil
    end
  end

  # Parse while loop: while (cond) body
  defp parse_while_statement(stmt) do
    stmt = String.trim_leading(stmt, "while") |> String.trim()

    case extract_condition_and_body(stmt) do
      {:ok, condition, body} ->
        cond_expr = parse_expression(condition)
        body_stmts = parse_loop_body(body)
        {:while, cond_expr, body_stmts}

      :error ->
        nil
    end
  end

  # Parse do-while loop: do { body } while (cond)
  defp parse_do_while_statement(stmt) do
    stmt = String.trim_leading(stmt, "do") |> String.trim()

    # Find the body (in braces) and then the while condition
    if String.starts_with?(stmt, "{") do
      case find_matching_brace(stmt, 0) do
        {:ok, end_pos} ->
          body = String.slice(stmt, 1..(end_pos - 1)//1)
          rest = String.slice(stmt, (end_pos + 1)..-1//1) |> String.trim()

          # Rest should be "while(cond)" or "while (cond)"
          if String.starts_with?(rest, "while") do
            rest = String.trim_leading(rest, "while") |> String.trim()

            case extract_condition_and_body(rest) do
              {:ok, condition, _} ->
                cond_expr = parse_expression(condition)
                body_stmts = parse_statements(body)
                {:do_while, body_stmts, cond_expr}

              :error ->
                nil
            end
          else
            nil
          end

        :error ->
          nil
      end
    else
      nil
    end
  end

  # Parse loop body - could be a single statement or braced block
  defp parse_loop_body(body) do
    body = String.trim(body)

    if String.starts_with?(body, "{") and String.ends_with?(body, "}") do
      inner = String.slice(body, 1..-2//1)
      parse_statements(inner)
    else
      [parse_statement(body)]
    end
  end

  # Parse exit statement: exit or exit N
  defp parse_exit_statement(stmt) do
    case Regex.run(~r/^exit\s*(\d+)?$/, stmt) do
      [_, code] when code != "" -> {:exit, String.to_integer(code)}
      [_] -> {:exit, 0}
      _ -> {:exit, 0}
    end
  end

  # Parse delete statement: delete arr[key] or delete arr
  defp parse_delete_statement(stmt) do
    case Regex.run(~r/^delete\s+(\w+)\[(.+)\]$/, stmt) do
      [_, array, key] ->
        {:delete_element, array, parse_expression(key)}

      nil ->
        case Regex.run(~r/^delete\s+(\w+)$/, stmt) do
          [_, array] -> {:delete_array, array}
          nil -> nil
        end
    end
  end

  # Parse array assignment: arr[key] = value
  defp parse_array_assign_statement(stmt) do
    case Regex.run(~r/^(\w+)\[(.+)\]\s*=\s*(.+)$/, stmt) do
      [_, array, key, value] ->
        {:array_assign, array, parse_expression(key), parse_expression(value)}

      nil ->
        nil
    end
  end

  # Parse array increment: arr[key]++
  defp parse_array_increment_statement(stmt) do
    case Regex.run(~r/^(\w+)\[(.+)\]\+\+$/, stmt) do
      [_, array, key] ->
        {:array_increment, array, parse_expression(key)}

      nil ->
        nil
    end
  end

  # Parse array add-assign: arr[key] += value
  defp parse_array_add_assign_statement(stmt) do
    case Regex.run(~r/^(\w+)\[(.+)\]\s*\+=\s*(.+)$/, stmt) do
      [_, array, key, value] ->
        {:array_add_assign, array, parse_expression(key), parse_expression(value)}

      nil ->
        nil
    end
  end

  # Compound assignment operators
  defp parse_sub_assign_statement(stmt) do
    case Regex.run(~r/^(\w+)\s*\-=\s*(.+)$/, stmt) do
      [_, var, expr] -> {:sub_assign, var, parse_expression(expr)}
      nil -> nil
    end
  end

  defp parse_mul_assign_statement(stmt) do
    case Regex.run(~r/^(\w+)\s*\*=\s*(.+)$/, stmt) do
      [_, var, expr] -> {:mul_assign, var, parse_expression(expr)}
      nil -> nil
    end
  end

  defp parse_div_assign_statement(stmt) do
    case Regex.run(~r/^(\w+)\s*\/=\s*(.+)$/, stmt) do
      [_, var, expr] -> {:div_assign, var, parse_expression(expr)}
      nil -> nil
    end
  end

  defp parse_pre_increment_statement(stmt) do
    case Regex.run(~r/^\+\+(\w+)$/, stmt) do
      [_, var] -> {:pre_increment, var}
      nil -> nil
    end
  end

  defp parse_decrement_statement(stmt) do
    case Regex.run(~r/^(\w+)\-\-$/, stmt) do
      [_, var] -> {:decrement, var}
      nil -> nil
    end
  end

  defp parse_pre_decrement_statement(stmt) do
    case Regex.run(~r/^\-\-(\w+)$/, stmt) do
      [_, var] -> {:pre_decrement, var}
      nil -> nil
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

      # Comma-separated arguments (but not inside function calls)
      # Returns {:comma_sep, exprs} to indicate OFS should be used
      # Must check BEFORE function_call and arithmetic to handle: print func(), func()
      has_comma_outside_parens?(args) ->
        {:comma_sep,
         args
         |> split_on_comma_respecting_parens()
         |> Enum.map(&String.trim/1)
         |> Enum.map(&parse_expression/1)}

      # Single function call (contains parens with balanced content)
      function_call_pattern?(args) ->
        [parse_expression(args)]

      # Single expression (possibly arithmetic)
      arithmetic_pattern?(args) ->
        [parse_expression(args)]

      # Space-separated fields/values (traditional awk: print $1 $2)
      # Returns {:concat, exprs} to indicate concatenation (no separator)
      true ->
        {:concat,
         args
         |> split_print_args()
         |> Enum.map(&parse_expression/1)}
    end
  end

  defp has_comma_outside_parens?(str), do: has_comma_outside_parens?(str, 0)
  defp has_comma_outside_parens?("", _), do: false

  defp has_comma_outside_parens?(<<"(", rest::binary>>, depth),
    do: has_comma_outside_parens?(rest, depth + 1)

  defp has_comma_outside_parens?(<<")", rest::binary>>, depth),
    do: has_comma_outside_parens?(rest, max(0, depth - 1))

  defp has_comma_outside_parens?(<<",", _::binary>>, 0), do: true

  defp has_comma_outside_parens?(<<_::utf8, rest::binary>>, depth),
    do: has_comma_outside_parens?(rest, depth)

  defp split_on_comma_respecting_parens(str), do: split_on_comma_respecting_parens(str, "", [], 0)

  defp split_on_comma_respecting_parens("", current, acc, _depth),
    do: Enum.reverse([current | acc])

  defp split_on_comma_respecting_parens(<<"(", rest::binary>>, current, acc, depth),
    do: split_on_comma_respecting_parens(rest, current <> "(", acc, depth + 1)

  defp split_on_comma_respecting_parens(<<")", rest::binary>>, current, acc, depth),
    do: split_on_comma_respecting_parens(rest, current <> ")", acc, max(0, depth - 1))

  defp split_on_comma_respecting_parens(<<",", rest::binary>>, current, acc, 0),
    do: split_on_comma_respecting_parens(rest, "", [current | acc], 0)

  defp split_on_comma_respecting_parens(<<char::utf8, rest::binary>>, current, acc, depth),
    do: split_on_comma_respecting_parens(rest, current <> <<char::utf8>>, acc, depth)

  # Split print args on whitespace, but respect quoted strings and parentheses
  defp split_print_args(str), do: split_print_args(str, "", [], false, 0)

  defp split_print_args("", current, acc, _in_string, _paren_depth) do
    if current == "" do
      Enum.reverse(acc)
    else
      Enum.reverse([current | acc])
    end
  end

  defp split_print_args(<<"\\", char::utf8, rest::binary>>, current, acc, in_string, paren_depth) do
    # Escaped character - keep it
    split_print_args(rest, current <> "\\" <> <<char::utf8>>, acc, in_string, paren_depth)
  end

  defp split_print_args(<<"\"", rest::binary>>, current, acc, in_string, paren_depth) do
    # Toggle quote mode
    split_print_args(rest, current <> "\"", acc, not in_string, paren_depth)
  end

  defp split_print_args(<<"(", rest::binary>>, current, acc, false, paren_depth) do
    # Opening paren outside quotes
    split_print_args(rest, current <> "(", acc, false, paren_depth + 1)
  end

  defp split_print_args(<<")", rest::binary>>, current, acc, false, paren_depth)
       when paren_depth > 0 do
    # Closing paren outside quotes
    split_print_args(rest, current <> ")", acc, false, paren_depth - 1)
  end

  defp split_print_args(<<char::utf8, rest::binary>>, current, acc, false, 0)
       when char in [?\s, ?\t] do
    # Whitespace separator outside quotes and parens
    if current == "" do
      split_print_args(rest, "", acc, false, 0)
    else
      split_print_args(rest, "", [current | acc], false, 0)
    end
  end

  defp split_print_args(<<char::utf8, rest::binary>>, current, acc, in_string, paren_depth) do
    split_print_args(rest, current <> <<char::utf8>>, acc, in_string, paren_depth)
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
      # Check for logical OR (lowest precedence) - but only if operator is outside parens
      logical_or_outside_parens?(expr) -> parse_logical_or(expr)
      # Check for logical AND - but only if operator is outside parens
      logical_and_outside_parens?(expr) -> parse_logical_and(expr)
      # Check for "in" operator (key in array)
      in_operator_pattern?(expr) -> parse_in_operator(expr)
      # Check for comparison operators
      comparison_pattern?(expr) -> parse_comparison(expr)
      # Check for function calls BEFORE arithmetic (function args may contain operators)
      function_call_pattern?(expr) -> parse_function_call(expr)
      # Check for arithmetic (includes +, -, *, /, %, ^, **)
      arithmetic_pattern?(expr) -> parse_arithmetic(expr)
      # Check for unary NOT
      String.starts_with?(expr, "!") -> parse_unary_not(expr)
      # Check for unary minus
      String.starts_with?(expr, "-") and not number_pattern?(expr) -> parse_unary_minus(expr)
      # Check for parenthesized expression - must come after binary operators
      paren_expr?(expr) -> parse_paren_expr(expr)
      # Check for array access: arr[key]
      array_access_pattern?(expr) -> parse_array_access(expr)
      String.starts_with?(expr, "$") -> parse_field_expression(expr)
      number_pattern?(expr) -> parse_number_literal(expr)
      word_pattern?(expr) -> {:variable, expr}
      true -> {:literal, expr}
    end
  end

  defp quoted_string?(s), do: String.starts_with?(s, "\"") and String.ends_with?(s, "\"")
  defp number_pattern?(s), do: s =~ ~r/^-?\d+(\.\d+)?$/
  defp word_pattern?(s), do: s =~ ~r/^\w+$/

  # Match function calls: name(args) where the ( after name matches the ) at end
  defp function_call_pattern?(s) do
    case Regex.run(~r/^(\w+)\(/, s) do
      [match, _name] ->
        # Check if it ends with ) and the ( after name matches the final )
        if String.ends_with?(s, ")") do
          # Start after "name(" and find where the matching ) is
          start_idx = String.length(match)
          rest = String.slice(s, start_idx..-1//1)
          # The matching ) should be at the very end (rest should close the paren)
          closes_at_end?(rest)
        else
          false
        end

      nil ->
        false
    end
  end

  # Check if a string that starts inside parens (after opening () closes at the end
  # e.g., "$1)" returns true, "$1), foo($2)" returns false
  defp closes_at_end?(s) do
    s
    |> String.graphemes()
    |> Enum.reduce_while({1, false, 0}, fn char, {depth, in_string, idx} ->
      new_state =
        cond do
          char == "\"" and not in_string -> {depth, true, idx + 1}
          char == "\"" and in_string -> {depth, false, idx + 1}
          char == "(" and not in_string -> {depth + 1, in_string, idx + 1}
          char == ")" and not in_string -> {depth - 1, in_string, idx + 1}
          true -> {depth, in_string, idx + 1}
        end

      {new_depth, _, new_idx} = new_state

      # If depth hits 0, check if we're at the end
      if new_depth == 0 do
        # We closed the initial paren - are we at the end of the string?
        if new_idx == String.length(s) do
          {:halt, :yes}
        else
          {:halt, :no}
        end
      else
        {:cont, new_state}
      end
    end)
    |> case do
      :yes -> true
      :no -> false
      _ -> false
    end
  end

  # Match ternary operator: expr ? val1 : val2
  defp ternary_pattern?(s), do: s =~ ~r/\?\s*[^:]+\s*:/

  # Match logical OR - only if || appears outside parentheses
  defp logical_or_outside_parens?(s) do
    not quoted_string?(s) and has_operator_outside_parens?(s, "||")
  end

  # Match logical AND - only if && appears outside parentheses
  defp logical_and_outside_parens?(s) do
    not quoted_string?(s) and has_operator_outside_parens?(s, "&&")
  end

  # Check if an operator appears at depth 0 (outside all parentheses)
  defp has_operator_outside_parens?(str, op) do
    has_operator_outside_parens?(str, op, 0)
  end

  defp has_operator_outside_parens?("", _op, _depth), do: false

  defp has_operator_outside_parens?(<<"(", rest::binary>>, op, depth) do
    has_operator_outside_parens?(rest, op, depth + 1)
  end

  defp has_operator_outside_parens?(<<")", rest::binary>>, op, depth) do
    has_operator_outside_parens?(rest, op, max(0, depth - 1))
  end

  defp has_operator_outside_parens?(str, op, 0) do
    if String.starts_with?(str, op) do
      true
    else
      <<_::utf8, rest::binary>> = str
      has_operator_outside_parens?(rest, op, 0)
    end
  end

  defp has_operator_outside_parens?(<<_::utf8, rest::binary>>, op, depth) do
    has_operator_outside_parens?(rest, op, depth)
  end

  # Match "in" operator
  defp in_operator_pattern?(s), do: s =~ ~r/\s+in\s+\w+$/ and not quoted_string?(s)
  # Match comparison operators
  defp comparison_pattern?(s),
    do: s =~ ~r/(==|!=|>=|<=|>(?!>)|<(?!<)|~|!~)/ and not quoted_string?(s)

  # Match expressions containing arithmetic operators: + - * / % ^ **
  defp arithmetic_pattern?(s), do: s =~ ~r/[\+\-\*\/\%\^]/ and not quoted_string?(s)
  # Match array access: name[key]
  defp array_access_pattern?(s), do: s =~ ~r/^\w+\[.+\]$/
  # Match parenthesized expression
  defp paren_expr?(s), do: String.starts_with?(s, "(") and String.ends_with?(s, ")")

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
    case Regex.run(~r/^(\w+)\(/, expr) do
      [_, name] ->
        # Extract content between first ( and last )
        start_idx = String.length(name) + 1
        end_idx = String.length(expr) - 1
        args_str = String.slice(expr, start_idx..(end_idx - 1)//1)

        args =
          if String.trim(args_str) == "" do
            []
          else
            args_str
            |> split_function_args()
            |> Enum.map(&String.trim/1)
            |> Enum.map(&parse_expression/1)
          end

        {:call, name, args}

      nil ->
        {:literal, expr}
    end
  end

  # Split function arguments on commas, respecting quotes and nested parens
  defp split_function_args(str), do: split_function_args(str, "", [], 0, false)

  defp split_function_args("", current, acc, _depth, _in_string) do
    Enum.reverse([current | acc])
  end

  defp split_function_args(<<"\\", char::utf8, rest::binary>>, current, acc, depth, in_string) do
    split_function_args(rest, current <> "\\" <> <<char::utf8>>, acc, depth, in_string)
  end

  defp split_function_args(<<"\"", rest::binary>>, current, acc, depth, in_string) do
    split_function_args(rest, current <> "\"", acc, depth, not in_string)
  end

  defp split_function_args(<<"(", rest::binary>>, current, acc, depth, false) do
    split_function_args(rest, current <> "(", acc, depth + 1, false)
  end

  defp split_function_args(<<")", rest::binary>>, current, acc, depth, false) when depth > 0 do
    split_function_args(rest, current <> ")", acc, depth - 1, false)
  end

  defp split_function_args(<<",", rest::binary>>, current, acc, 0, false) do
    split_function_args(rest, "", [current | acc], 0, false)
  end

  defp split_function_args(<<char::utf8, rest::binary>>, current, acc, depth, in_string) do
    split_function_args(rest, current <> <<char::utf8>>, acc, depth, in_string)
  end

  # Parse logical OR: a || b
  defp parse_logical_or(expr) do
    case split_on_operator(expr, "||") do
      {left, right} ->
        {:or, parse_expression(left), parse_expression(right)}

      nil ->
        {:literal, expr}
    end
  end

  # Parse logical AND: a && b
  defp parse_logical_and(expr) do
    case split_on_operator(expr, "&&") do
      {left, right} ->
        {:and, parse_expression(left), parse_expression(right)}

      nil ->
        {:literal, expr}
    end
  end

  # Parse "in" operator: key in array
  defp parse_in_operator(expr) do
    case Regex.run(~r/^(.+)\s+in\s+(\w+)$/, expr) do
      [_, key, array] ->
        {:in, parse_expression(String.trim(key)), array}

      nil ->
        {:literal, expr}
    end
  end

  # Parse comparison expressions
  defp parse_comparison(expr) do
    # Order matters - check longer operators first
    cond do
      match = Regex.run(~r/^(.+?)\s*(==)\s*(.+)$/, expr) ->
        [_, left, op, right] = match
        {String.to_atom(op), parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+?)\s*(!=)\s*(.+)$/, expr) ->
        [_, left, op, right] = match
        {String.to_atom(op), parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+?)\s*(>=)\s*(.+)$/, expr) ->
        [_, left, op, right] = match
        {String.to_atom(op), parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+?)\s*(<=)\s*(.+)$/, expr) ->
        [_, left, op, right] = match
        {String.to_atom(op), parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+?)\s*(!~)\s*\/(.+)\/$/, expr) ->
        [_, left, _, pattern] = match
        {:not_match, parse_expression(left), pattern}

      match = Regex.run(~r/^(.+?)\s*(~)\s*\/(.+)\/$/, expr) ->
        [_, left, _, pattern] = match
        {:match, parse_expression(left), pattern}

      match = Regex.run(~r/^(.+?)\s*(>)\s*(.+)$/, expr) ->
        [_, left, op, right] = match
        {String.to_atom(op), parse_expression(left), parse_expression(right)}

      match = Regex.run(~r/^(.+?)\s*(<)\s*(.+)$/, expr) ->
        [_, left, op, right] = match
        {String.to_atom(op), parse_expression(left), parse_expression(right)}

      true ->
        {:literal, expr}
    end
  end

  # Parse unary NOT: !expr
  defp parse_unary_not(expr) do
    rest = String.trim_leading(expr, "!") |> String.trim()
    {:not, parse_expression(rest)}
  end

  # Parse unary minus: -expr
  defp parse_unary_minus(expr) do
    rest = String.trim_leading(expr, "-") |> String.trim()
    {:negate, parse_expression(rest)}
  end

  # Parse parenthesized expression
  defp parse_paren_expr(expr) do
    inner = String.slice(expr, 1..-2//1)
    parse_expression(inner)
  end

  # Parse array access: arr[key]
  defp parse_array_access(expr) do
    case Regex.run(~r/^(\w+)\[(.+)\]$/, expr) do
      [_, array, key] ->
        {:array_access, array, parse_expression(key)}

      nil ->
        {:literal, expr}
    end
  end

  # Parse arithmetic expressions with proper operator precedence
  # Handles: +, -, *, /, %, ^, **
  defp parse_arithmetic(expr) do
    # Try operators in order of precedence (lowest first, so they bind loosest)
    cond do
      # Addition (lowest precedence after logical)
      match = split_on_operator_right(expr, "+") ->
        {left, right} = match
        {:add, parse_expression(left), parse_expression(right)}

      # Subtraction
      match = split_on_operator_right(expr, "-") ->
        {left, right} = match
        # Make sure it's not a unary minus
        if String.trim(left) == "" do
          {:negate, parse_expression(right)}
        else
          {:sub, parse_expression(left), parse_expression(right)}
        end

      # Multiplication
      match = split_on_operator_right(expr, "*") ->
        {left, right} = match
        # Check for ** (power)
        if String.ends_with?(left, "*") do
          left = String.trim_trailing(left, "*")
          {:pow, parse_expression(left), parse_expression(right)}
        else
          {:mul, parse_expression(left), parse_expression(right)}
        end

      # Division
      match = split_on_operator_right(expr, "/") ->
        {left, right} = match
        {:div, parse_expression(left), parse_expression(right)}

      # Modulo
      match = split_on_operator_right(expr, "%") ->
        {left, right} = match
        {:mod, parse_expression(left), parse_expression(right)}

      # Power (^)
      match = split_on_operator_right(expr, "^") ->
        {left, right} = match
        {:pow, parse_expression(left), parse_expression(right)}

      true ->
        {:literal, expr}
    end
  end

  # Split expression on operator, respecting parentheses
  # Returns the rightmost occurrence outside parens
  defp split_on_operator(expr, op) do
    # Find last occurrence of operator outside parentheses
    split_on_operator_impl(expr, op, "", 0, nil)
  end

  defp split_on_operator_impl("", _op, _current, _depth, nil), do: nil
  defp split_on_operator_impl("", _op, _current, _depth, result), do: result

  defp split_on_operator_impl(<<?(, rest::binary>>, op, current, depth, result) do
    split_on_operator_impl(rest, op, current <> "(", depth + 1, result)
  end

  defp split_on_operator_impl(<<?), rest::binary>>, op, current, depth, result) do
    split_on_operator_impl(rest, op, current <> ")", max(0, depth - 1), result)
  end

  defp split_on_operator_impl(str, op, current, 0, result) do
    op_len = String.length(op)

    if String.starts_with?(str, op) do
      rest = String.slice(str, op_len..-1//1)
      # Found operator at depth 0, record position and continue looking for more
      split_on_operator_impl(rest, op, current <> op, 0, {current, rest})
    else
      <<char::utf8, rest::binary>> = str
      # Keep looking, preserve any previously found result
      split_on_operator_impl(rest, op, current <> <<char::utf8>>, 0, result)
    end
  end

  defp split_on_operator_impl(<<char::utf8, rest::binary>>, op, current, depth, result) do
    split_on_operator_impl(rest, op, current <> <<char::utf8>>, depth, result)
  end

  # Split on operator from the right (for left-associative operators)
  defp split_on_operator_right(expr, op) do
    # Scan from right to find last occurrence at depth 0
    chars = String.graphemes(expr)
    find_rightmost_operator(Enum.reverse(chars), op, "", 0, String.length(op))
  end

  defp find_rightmost_operator([], _op, _acc, _depth, _op_len), do: nil

  defp find_rightmost_operator([")" | rest], op, acc, depth, op_len) do
    find_rightmost_operator(rest, op, ")" <> acc, depth + 1, op_len)
  end

  defp find_rightmost_operator(["(" | rest], op, acc, depth, op_len) do
    find_rightmost_operator(rest, op, "(" <> acc, max(0, depth - 1), op_len)
  end

  defp find_rightmost_operator(chars, op, acc, 0, op_len) do
    # Check if we have the operator at current position
    current = Enum.take(chars, op_len) |> Enum.reverse() |> Enum.join()

    if current == op do
      left = Enum.drop(chars, op_len) |> Enum.reverse() |> Enum.join()
      {String.trim(left), String.trim(acc)}
    else
      [char | rest] = chars
      find_rightmost_operator(rest, op, char <> acc, 0, op_len)
    end
  end

  defp find_rightmost_operator([char | rest], op, acc, depth, op_len) do
    find_rightmost_operator(rest, op, char <> acc, depth, op_len)
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
