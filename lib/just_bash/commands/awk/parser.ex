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
    try do
      rules = parse_rules(program_str)
      {:ok, rules}
    rescue
      e -> {:error, Exception.message(e)}
    end
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
  end

  defp parse_statement(stmt) do
    cond do
      String.starts_with?(stmt, "print ") or stmt == "print" ->
        parse_print_statement(stmt)

      String.starts_with?(stmt, "printf ") ->
        parse_printf_statement(stmt)

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

  defp parse_print_args(args) do
    if String.contains?(args, ",") do
      args
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_expression/1)
    else
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
      String.starts_with?(expr, "$") -> parse_field_expression(expr)
      number_pattern?(expr) -> parse_number_literal(expr)
      word_pattern?(expr) -> {:variable, expr}
      word_addition_pattern?(expr) -> parse_word_addition(expr)
      field_addition_pattern?(expr) -> parse_field_addition(expr)
      true -> {:literal, expr}
    end
  end

  defp quoted_string?(s), do: String.starts_with?(s, "\"") and String.ends_with?(s, "\"")
  defp number_pattern?(s), do: s =~ ~r/^\d+(\.\d+)?$/
  defp word_pattern?(s), do: s =~ ~r/^\w+$/
  defp word_addition_pattern?(s), do: s =~ ~r/^\w+\s*\+\s*/
  defp field_addition_pattern?(s), do: s =~ ~r/^\$\d+\s*\+\s*/

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

  defp parse_word_addition(expr) do
    case Regex.run(~r/^(\w+|\$\d+)\s*\+\s*(.+)$/, expr) do
      [_, left, right] ->
        {:add, parse_expression(left), parse_expression(right)}

      nil ->
        {:literal, expr}
    end
  end

  defp parse_field_addition(expr) do
    case Regex.run(~r/^(\$\d+)\s*\+\s*(.+)$/, expr) do
      [_, left, right] ->
        {:add, parse_expression(left), parse_expression(right)}

      nil ->
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
