defmodule JustBash.Parser.WordParts do
  @moduledoc """
  Word Parts Parser

  Parses word token values into AST nodes for:
  - Variable expansion: $VAR, ${VAR}, ${VAR:-default}
  - Command substitution: $(cmd), `cmd`
  - Arithmetic expansion: $((expr))
  - Glob patterns: *, ?, [...]
  - Quoted strings: 'literal', "with $expansion"
  - Tilde expansion: ~, ~user
  """

  alias JustBash.AST
  alias JustBash.Parser.WordParts.Bracket
  alias JustBash.Parser.WordParts.Expansion

  @type parse_result :: [AST.word_part()]

  @doc """
  Parse a word value into its component parts.

  ## Options
  - `:quoted` - true if the token was double-quoted
  - `:single_quoted` - true if the token was single-quoted
  - `:assignment` - true if this is the RHS of an assignment
  """
  @spec parse(String.t(), keyword()) :: parse_result()
  def parse(value, opts \\ []) do
    quoted = Keyword.get(opts, :quoted, false)
    single_quoted = Keyword.get(opts, :single_quoted, false)
    is_assignment = Keyword.get(opts, :assignment, false)

    cond do
      single_quoted ->
        [AST.single_quoted(value)]

      quoted ->
        inner_parts = parse_double_quoted_content(value)
        [AST.double_quoted(inner_parts)]

      true ->
        parse_unquoted(value, is_assignment)
    end
  end

  defp parse_unquoted(value, is_assignment) do
    parse_unquoted_loop(value, 0, String.length(value), "", [], is_assignment)
  end

  defp parse_unquoted_loop(_value, i, len, literal, parts, _is_assignment) when i >= len do
    flush_literal(literal, parts)
  end

  defp parse_unquoted_loop(value, i, len, literal, parts, is_assignment) do
    char = String.at(value, i)

    ctx = %{
      value: value,
      i: i,
      len: len,
      literal: literal,
      parts: parts,
      is_assignment: is_assignment
    }

    dispatch_unquoted_char(char, ctx)
  end

  defp dispatch_unquoted_char("\\", %{i: i, len: len} = ctx) when i + 1 < len do
    handle_unquoted_escape(ctx)
  end

  defp dispatch_unquoted_char("'", ctx), do: handle_single_quote(ctx)
  defp dispatch_unquoted_char("\"", ctx), do: handle_double_quote(ctx)

  defp dispatch_unquoted_char("$", %{value: value, i: i} = ctx) do
    if String.at(value, i + 1) == "'" do
      handle_ansi_c_quote(ctx)
    else
      handle_dollar_expansion(ctx)
    end
  end

  defp dispatch_unquoted_char("`", ctx), do: handle_backtick(ctx)

  defp dispatch_unquoted_char("~", %{value: value, i: i} = ctx) do
    if i == 0 or String.at(value, i - 1) in ["=", ":"] do
      handle_tilde(ctx, "~")
    else
      append_char_and_continue(ctx, "~")
    end
  end

  defp dispatch_unquoted_char("*", ctx), do: handle_glob_char(ctx, "*")
  defp dispatch_unquoted_char("?", ctx), do: handle_glob_char(ctx, "?")
  defp dispatch_unquoted_char("{", ctx), do: handle_brace(ctx, "{")
  defp dispatch_unquoted_char("[", ctx), do: handle_bracket(ctx, "[")
  defp dispatch_unquoted_char(char, ctx), do: append_char_and_continue(ctx, char)

  defp append_char_and_continue(
         %{
           value: value,
           i: i,
           len: len,
           literal: literal,
           parts: parts,
           is_assignment: is_assignment
         },
         char
       ) do
    parse_unquoted_loop(value, i + 1, len, literal <> char, parts, is_assignment)
  end

  defp handle_unquoted_escape(%{
         value: value,
         i: i,
         len: len,
         literal: literal,
         parts: parts,
         is_assignment: is_assignment
       }) do
    next = String.at(value, i + 1)

    if next in ["$", "`", "\\", "\"", "\n"] do
      parse_unquoted_loop(value, i + 2, len, literal <> next, parts, is_assignment)
    else
      parse_unquoted_loop(value, i + 2, len, literal <> "\\" <> next, parts, is_assignment)
    end
  end

  defp handle_single_quote(%{
         value: value,
         i: i,
         len: len,
         literal: literal,
         parts: parts,
         is_assignment: is_assignment
       }) do
    parts = flush_literal(literal, parts)
    {quoted_content, end_idx} = parse_single_quoted(value, i + 1)
    new_parts = parts ++ [AST.single_quoted(quoted_content)]
    parse_unquoted_loop(value, end_idx, len, "", new_parts, is_assignment)
  end

  defp handle_double_quote(%{
         value: value,
         i: i,
         len: len,
         literal: literal,
         parts: parts,
         is_assignment: is_assignment
       }) do
    parts = flush_literal(literal, parts)
    {inner_parts, end_idx} = parse_double_quoted(value, i + 1)
    new_parts = parts ++ [AST.double_quoted(inner_parts)]
    parse_unquoted_loop(value, end_idx, len, "", new_parts, is_assignment)
  end

  defp handle_ansi_c_quote(%{
         value: value,
         i: i,
         len: len,
         literal: literal,
         parts: parts,
         is_assignment: is_assignment
       }) do
    parts = flush_literal(literal, parts)
    {ansi_content, end_idx} = parse_ansi_c_quoted(value, i + 2)
    new_parts = parts ++ [AST.literal(ansi_content)]
    parse_unquoted_loop(value, end_idx, len, "", new_parts, is_assignment)
  end

  defp handle_dollar_expansion(%{
         value: value,
         i: i,
         len: len,
         literal: literal,
         parts: parts,
         is_assignment: is_assignment
       }) do
    parts = flush_literal(literal, parts)
    {part, end_idx} = Expansion.parse(value, i)
    new_parts = parts ++ [part]
    parse_unquoted_loop(value, end_idx, len, "", new_parts, is_assignment)
  end

  defp handle_backtick(%{
         value: value,
         i: i,
         len: len,
         literal: literal,
         parts: parts,
         is_assignment: is_assignment
       }) do
    parts = flush_literal(literal, parts)
    {part, end_idx} = Expansion.parse_backtick(value, i)
    new_parts = parts ++ [part]
    parse_unquoted_loop(value, end_idx, len, "", new_parts, is_assignment)
  end

  defp handle_tilde(
         %{
           value: value,
           i: i,
           len: len,
           literal: literal,
           parts: parts,
           is_assignment: is_assignment
         },
         char
       ) do
    tilde_end = find_tilde_end(value, i)
    after_tilde = String.at(value, tilde_end)

    if after_tilde in [nil, "/", ":"] do
      parts = flush_literal(literal, parts)
      user = extract_tilde_user(value, i, tilde_end)
      new_parts = parts ++ [%AST.TildeExpansion{user: user}]
      parse_unquoted_loop(value, tilde_end, len, "", new_parts, is_assignment)
    else
      parse_unquoted_loop(value, i + 1, len, literal <> char, parts, is_assignment)
    end
  end

  defp extract_tilde_user(value, i, tilde_end) do
    if tilde_end > i + 1, do: String.slice(value, (i + 1)..(tilde_end - 1)), else: nil
  end

  defp handle_glob_char(
         %{
           value: value,
           i: i,
           len: len,
           literal: literal,
           parts: parts,
           is_assignment: is_assignment
         },
         char
       ) do
    parts = flush_literal(literal, parts)
    new_parts = parts ++ [%AST.Glob{pattern: char}]
    parse_unquoted_loop(value, i + 1, len, "", new_parts, is_assignment)
  end

  defp handle_brace(
         %{
           value: value,
           i: i,
           len: len,
           literal: literal,
           parts: parts,
           is_assignment: is_assignment
         },
         char
       ) do
    case try_parse_brace_expansion(value, i) do
      {:ok, brace_exp, end_idx} ->
        parts = flush_literal(literal, parts)
        new_parts = parts ++ [brace_exp]
        parse_unquoted_loop(value, end_idx, len, "", new_parts, is_assignment)

      :not_brace_expansion ->
        parse_unquoted_loop(value, i + 1, len, literal <> char, parts, is_assignment)
    end
  end

  defp handle_bracket(
         %{
           value: value,
           i: i,
           len: len,
           literal: literal,
           parts: parts,
           is_assignment: is_assignment
         },
         char
       ) do
    case Bracket.find_glob_bracket_end(value, i) do
      {:ok, end_idx} ->
        pattern = String.slice(value, i..end_idx)

        # If bracket content contains $, it's not a pure glob pattern
        # The $ should be expanded first, so treat [ as a literal
        if String.contains?(pattern, "$") do
          parse_unquoted_loop(value, i + 1, len, literal <> char, parts, is_assignment)
        else
          parts = flush_literal(literal, parts)
          new_parts = parts ++ [%AST.Glob{pattern: pattern}]
          parse_unquoted_loop(value, end_idx + 1, len, "", new_parts, is_assignment)
        end

      :error ->
        parse_unquoted_loop(value, i + 1, len, literal <> char, parts, is_assignment)
    end
  end

  defp flush_literal("", parts), do: parts
  defp flush_literal(literal, parts), do: parts ++ [AST.literal(literal)]

  defp parse_single_quoted(value, start) do
    case :binary.match(value, "'", scope: {start, byte_size(value) - start}) do
      {pos, _} ->
        content = String.slice(value, start..(pos - 1)//1)
        {content, pos + 1}

      :nomatch ->
        content = String.slice(value, start..-1//1)
        {content, String.length(value)}
    end
  end

  defp parse_double_quoted(value, start) do
    len = String.length(value)
    parse_double_quoted_loop(value, start, len, "", [])
  end

  defp parse_double_quoted_loop(_value, i, len, literal, parts) when i >= len do
    {flush_literal(literal, parts), i}
  end

  defp parse_double_quoted_loop(value, i, len, literal, parts) do
    char = String.at(value, i)

    cond do
      char == "\"" ->
        {flush_literal(literal, parts), i + 1}

      char == "\\" and i + 1 < len ->
        next = String.at(value, i + 1)

        if next in ["\"", "\\", "$", "`", "\n"] do
          parse_double_quoted_loop(value, i + 2, len, literal <> next, parts)
        else
          parse_double_quoted_loop(value, i + 1, len, literal <> char, parts)
        end

      char == "$" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = Expansion.parse(value, i)
        new_parts = parts ++ [part]
        parse_double_quoted_loop(value, end_idx, len, "", new_parts)

      char == "`" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = Expansion.parse_backtick(value, i)
        new_parts = parts ++ [part]
        parse_double_quoted_loop(value, end_idx, len, "", new_parts)

      true ->
        parse_double_quoted_loop(value, i + 1, len, literal <> char, parts)
    end
  end

  defp parse_double_quoted_content(value) do
    len = String.length(value)
    parse_dq_content_loop(value, 0, len, "", [])
  end

  defp parse_dq_content_loop(_value, i, len, literal, parts) when i >= len do
    flush_literal(literal, parts)
  end

  defp parse_dq_content_loop(value, i, len, literal, parts) do
    char = String.at(value, i)

    cond do
      char == "\\" and i + 1 < len ->
        next = String.at(value, i + 1)

        # In double quotes, these escapes are processed:
        # \\ -> \, \" -> ", \$ -> $, \` -> `, \newline -> (line continuation)
        if next in ["\\", "\"", "$", "`"] do
          parse_dq_content_loop(value, i + 2, len, literal <> next, parts)
        else
          # Other backslashes are preserved literally
          parse_dq_content_loop(value, i + 1, len, literal <> char, parts)
        end

      char == "$" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = Expansion.parse(value, i)
        new_parts = parts ++ [part]
        parse_dq_content_loop(value, end_idx, len, "", new_parts)

      char == "`" ->
        parts = flush_literal(literal, parts)
        {part, end_idx} = Expansion.parse_backtick(value, i)
        new_parts = parts ++ [part]
        parse_dq_content_loop(value, end_idx, len, "", new_parts)

      true ->
        parse_dq_content_loop(value, i + 1, len, literal <> char, parts)
    end
  end

  defp parse_ansi_c_quoted(value, start) do
    len = String.length(value)
    parse_ansi_c_loop(value, start, len, "")
  end

  defp parse_ansi_c_loop(_value, i, len, acc) when i >= len, do: {acc, i}

  defp parse_ansi_c_loop(value, i, len, acc) do
    char = String.at(value, i)

    cond do
      char == "'" ->
        {acc, i + 1}

      char == "\\" and i + 1 < len ->
        next = String.at(value, i + 1)

        cond do
          # Hex escape: \xNN
          next == "x" and i + 3 < len ->
            case parse_hex_escape(value, i + 2) do
              {:ok, char_val, new_i} ->
                parse_ansi_c_loop(value, new_i, len, acc <> char_val)

              :error ->
                parse_ansi_c_loop(value, i + 2, len, acc <> "\\x")
            end

          # Octal escape: \NNN (0-7 digits)
          next in ["0", "1", "2", "3", "4", "5", "6", "7"] ->
            {octal_str, new_i} = parse_octal_escape(value, i + 1, len)
            char_val = <<String.to_integer(octal_str, 8)>>
            parse_ansi_c_loop(value, new_i, len, acc <> char_val)

          true ->
            expanded = ansi_escape_char(next)
            parse_ansi_c_loop(value, i + 2, len, acc <> expanded)
        end

      true ->
        parse_ansi_c_loop(value, i + 1, len, acc <> char)
    end
  end

  defp parse_hex_escape(value, start) do
    hex1 = String.at(value, start)
    hex2 = String.at(value, start + 1)

    cond do
      hex_digit?(hex1) and hex_digit?(hex2) ->
        char_val = <<String.to_integer(hex1 <> hex2, 16)>>
        {:ok, char_val, start + 2}

      hex_digit?(hex1) ->
        char_val = <<String.to_integer(hex1, 16)>>
        {:ok, char_val, start + 1}

      true ->
        :error
    end
  end

  defp hex_digit?(nil), do: false
  defp hex_digit?(c), do: c =~ ~r/^[0-9a-fA-F]$/

  defp parse_octal_escape(value, start, len) do
    # Read up to 3 octal digits
    {digits, end_i} = read_octal_digits(value, start, len, 3)
    {digits, end_i}
  end

  defp read_octal_digits(_value, i, _len, 0), do: {"", i}
  defp read_octal_digits(_value, i, len, _remaining) when i >= len, do: {"", i}

  defp read_octal_digits(value, i, len, remaining) do
    char = String.at(value, i)

    if char in ["0", "1", "2", "3", "4", "5", "6", "7"] do
      {more, end_i} = read_octal_digits(value, i + 1, len, remaining - 1)
      {char <> more, end_i}
    else
      {"", i}
    end
  end

  @ansi_escape_map %{
    "n" => "\n",
    "t" => "\t",
    "r" => "\r",
    "\\" => "\\",
    "'" => "'",
    "\"" => "\"",
    "a" => "\a",
    "b" => "\b",
    "e" => "\e",
    "E" => "\e",
    "f" => "\f",
    "v" => "\v"
  }

  defp ansi_escape_char(char) do
    Map.get(@ansi_escape_map, char, "\\" <> char)
  end

  defp find_tilde_end(value, start) do
    find_tilde_end_loop(value, start + 1)
  end

  defp find_tilde_end_loop(value, i) do
    char = String.at(value, i)

    if char && char =~ ~r/[a-zA-Z0-9_-]/ do
      find_tilde_end_loop(value, i + 1)
    else
      i
    end
  end

  defp try_parse_brace_expansion(value, start) do
    len = String.length(value)

    case find_brace_expansion_end(value, start + 1, len, 1) do
      {:ok, end_idx} ->
        content = String.slice(value, (start + 1)..(end_idx - 1)//1)
        parse_brace_content(content, end_idx)

      :error ->
        :not_brace_expansion
    end
  end

  defp parse_brace_content(content, end_idx) do
    cond do
      String.contains?(content, "..") ->
        try_parse_brace_range_expansion(content, end_idx)

      String.contains?(content, ",") ->
        items = parse_brace_list(content)
        {:ok, %AST.BraceExpansion{items: items}, end_idx + 1}

      true ->
        :not_brace_expansion
    end
  end

  defp try_parse_brace_range_expansion(content, end_idx) do
    case parse_brace_range(content) do
      {:ok, items} -> {:ok, %AST.BraceExpansion{items: items}, end_idx + 1}
      :error -> :not_brace_expansion
    end
  end

  defp find_brace_expansion_end(_value, i, len, _depth) when i >= len, do: :error
  defp find_brace_expansion_end(_value, i, _len, 0), do: {:ok, i - 1}

  defp find_brace_expansion_end(value, i, len, depth) do
    char = String.at(value, i)

    cond do
      char == "{" ->
        find_brace_expansion_end(value, i + 1, len, depth + 1)

      char == "}" ->
        if depth == 1, do: {:ok, i}, else: find_brace_expansion_end(value, i + 1, len, depth - 1)

      char == "\\" and i + 1 < len ->
        find_brace_expansion_end(value, i + 2, len, depth)

      true ->
        find_brace_expansion_end(value, i + 1, len, depth)
    end
  end

  defp parse_brace_range(content) do
    case String.split(content, "..") do
      [start_str, end_str] ->
        parse_range_parts(start_str, end_str, nil)

      [start_str, end_str, step_str] ->
        case Integer.parse(step_str) do
          {step, ""} -> parse_range_parts(start_str, end_str, step)
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_range_parts(start_str, end_str, step) do
    if String.length(start_str) == 1 and String.length(end_str) == 1 do
      {:ok, [{:range, start_str, end_str, step}]}
    else
      case {Integer.parse(start_str), Integer.parse(end_str)} do
        {{start_num, ""}, {end_num, ""}} ->
          {:ok, [{:range, start_num, end_num, step}]}

        _ ->
          :error
      end
    end
  end

  defp parse_brace_list(content) do
    split_brace_items(content)
    |> Enum.map(&parse_brace_item/1)
  end

  defp parse_brace_item(item) do
    if String.contains?(item, "..") do
      parse_brace_item_as_range(item)
    else
      {:word, AST.word(parse(item))}
    end
  end

  defp parse_brace_item_as_range(item) do
    case parse_brace_range(item) do
      {:ok, [{:range, s, e, step}]} -> {:range, s, e, step}
      :error -> {:word, AST.word(parse(item))}
    end
  end

  defp split_brace_items(content) do
    len = String.length(content)
    split_brace_items_loop(content, 0, len, 0, "", [])
  end

  defp split_brace_items_loop(_content, i, len, _depth, acc, items) when i >= len do
    Enum.reverse([acc | items])
  end

  defp split_brace_items_loop(content, i, len, depth, acc, items) do
    char = String.at(content, i)

    cond do
      char == "{" ->
        split_brace_items_loop(content, i + 1, len, depth + 1, acc <> char, items)

      char == "}" ->
        split_brace_items_loop(content, i + 1, len, depth - 1, acc <> char, items)

      char == "," and depth == 0 ->
        split_brace_items_loop(content, i + 1, len, depth, "", [acc | items])

      char == "\\" and i + 1 < len ->
        next = String.at(content, i + 1)
        split_brace_items_loop(content, i + 2, len, depth, acc <> char <> next, items)

      true ->
        split_brace_items_loop(content, i + 1, len, depth, acc <> char, items)
    end
  end
end
