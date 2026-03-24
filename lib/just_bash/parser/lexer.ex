defmodule JustBash.Parser.Lexer do
  @moduledoc """
  Hand-written lexer for bash scripts.

  Processes input as a binary with explicit state tracking, enabling
  native heredoc body consumption without the limitations of a
  context-free parser generator.
  """

  alias __MODULE__.BraceExpansion
  alias __MODULE__.Error, as: LexerError
  alias __MODULE__.Token

  @reserved ~w(if then else elif fi for while until do done case esac in function select time coproc)
  @max_nesting_depth 200
  @leading_tabs ~r/^\t+/

  @ansi_c_escape_map %{
    ?n => "\n",
    ?t => "\t",
    ?r => "\r",
    ?\\ => "\\",
    ?' => "'",
    ?" => "\"",
    ?a => "\a",
    ?b => "\b",
    ?e => "\e",
    ?E => "\e",
    ?f => "\f",
    ?v => "\v"
  }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Tokenize input string into a list of tokens.

  Returns `{:ok, tokens}` on success or `{:error, %LexerError{}}` on failure.
  Use `tokenize!/1` if you prefer exceptions.
  """
  @spec tokenize(String.t()) :: {:ok, [Token.t()]} | {:error, LexerError.t()}
  def tokenize(input) when is_binary(input) do
    tokens = do_tokenize(input, 0, 1, 1, [], [])
    tokens = BraceExpansion.process(tokens)
    {:ok, tokens ++ [Token.eof(input)]}
  rescue
    e in LexerError -> {:error, e}
  end

  @doc """
  Tokenize input string into a list of tokens.

  Raises `JustBash.Parser.Lexer.Error` on failure.
  """
  @spec tokenize!(String.t()) :: [Token.t()]
  def tokenize!(input) when is_binary(input) do
    case tokenize(input) do
      {:ok, tokens} -> tokens
      {:error, error} -> raise error
    end
  end

  # ── Main Loop ───────────────────────────────────────────────────────
  #
  # Walks the input byte-by-byte, dispatching to specialized readers.
  # `pending` tracks heredoc delimiters whose bodies have not yet been consumed.

  defp do_tokenize(input, pos, line, col, acc, pending) do
    {pos, line, col} = skip_ws(input, pos, line, col)

    if pos >= byte_size(input) do
      Enum.reverse(acc)
    else
      tokenize_at(input, pos, line, col, acc, pending)
    end
  end

  defp tokenize_at(input, pos, line, col, acc, pending) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?\n -> handle_newline(input, pos, line, col, acc, pending)
      byte == ?# -> handle_comment(input, pos, line, col, acc, pending)
      true -> handle_operator_or_word(input, pos, line, col, acc, pending, byte)
    end
  end

  # ── Newline ─────────────────────────────────────────────────────────

  defp handle_newline(input, pos, line, col, acc, pending) do
    token = mk(:newline, "\n", pos, line, col)
    acc = [token | acc]

    if pending != [] do
      {body_tokens, new_pos, new_line} = consume_heredocs(input, pos + 1, line + 1, pending)
      do_tokenize(input, new_pos, new_line, 1, body_tokens ++ acc, [])
    else
      do_tokenize(input, pos + 1, line + 1, 1, acc, [])
    end
  end

  # ── Comment ─────────────────────────────────────────────────────────

  defp handle_comment(input, pos, line, col, acc, pending) do
    end_pos = scan_to_newline(input, pos)
    text = binary_part(input, pos, end_pos - pos)
    token = mk(:comment, text, pos, line, col)
    {_, new_col} = advance(text, line, col)
    do_tokenize(input, end_pos, line, new_col, [token | acc], pending)
  end

  # ── Operators ───────────────────────────────────────────────────────

  defp handle_operator_or_word(input, pos, line, col, acc, pending, byte) do
    case try_operator(input, pos, byte) do
      {type, raw, end_pos} ->
        token = mk(type, raw, pos, line, col)
        {new_line, new_col} = advance(raw, line, col)

        if type in [:dless, :dlessdash] do
          read_heredoc_delim_and_continue(
            input,
            end_pos,
            new_line,
            new_col,
            [token | acc],
            pending,
            type
          )
        else
          do_tokenize(input, end_pos, new_line, new_col, [token | acc], pending)
        end

      nil ->
        handle_word(input, pos, line, col, acc, pending)
    end
  end

  # Try to match an operator at the current position.
  # Returns {type, raw_string, end_pos} or nil.
  defp try_operator(input, pos, byte) do
    size = byte_size(input)
    b2 = if pos + 1 < size, do: :binary.at(input, pos + 1)
    b3 = if pos + 2 < size, do: :binary.at(input, pos + 2)

    # Three-character operators (longest match first)
    case {byte, b2, b3} do
      {?<, ?<, ?-} -> {:dlessdash, "<<-", pos + 3}
      {?<, ?<, ?<} -> {:tless, "<<<", pos + 3}
      {?;, ?;, ?&} -> {:semi_semi_and, ";;&", pos + 3}
      {?&, ?>, ?>} -> {:and_dgreat, "&>>", pos + 3}
      _ -> try_op2(pos, byte, b2)
    end
  end

  @two_char_ops %{
    {?&, ?&} => {:and_and, "&&"},
    {?|, ?|} => {:or_or, "||"},
    {?<, ?<} => {:dless, "<<"},
    {?>, ?>} => {:dgreat, ">>"},
    {?<, ?&} => {:lessand, "<&"},
    {?>, ?&} => {:greatand, ">&"},
    {?<, ?>} => {:lessgreat, "<>"},
    {?>, ?|} => {:clobber, ">|"},
    {?|, ?&} => {:pipe_amp, "|&"},
    {?;, ?;} => {:dsemi, ";;"},
    {?;, ?&} => {:semi_and, ";&"},
    {?&, ?>} => {:and_great, "&>"},
    {?[, ?[} => {:dbrack_start, "[["},
    {?], ?]} => {:dbrack_end, "]]"},
    {?(, ?(} => {:dparen_start, "(("},
    {?), ?)} => {:dparen_end, "))"}
  }

  defp try_op2(pos, byte, b2) do
    case Map.get(@two_char_ops, {byte, b2}) do
      {type, raw} -> {type, raw, pos + 2}
      nil -> try_op1(pos, byte, b2)
    end
  end

  defp try_op1(pos, byte, b2) do
    case byte do
      ?| -> {:pipe, "|", pos + 1}
      ?& -> {:amp, "&", pos + 1}
      ?; -> {:semicolon, ";", pos + 1}
      ?( -> {:lparen, "(", pos + 1}
      ?) -> {:rparen, ")", pos + 1}
      ?{ -> {:lbrace, "{", pos + 1}
      ?} -> {:rbrace, "}", pos + 1}
      ?< -> {:less, "<", pos + 1}
      ?> -> {:great, ">", pos + 1}
      ?! when b2 != ?= -> {:bang, "!", pos + 1}
      _ -> nil
    end
  end

  # ── Words ───────────────────────────────────────────────────────────

  defp handle_word(input, pos, line, col, acc, pending) do
    {parts, end_pos} = read_word(input, pos)

    if parts == [] do
      byte = :binary.at(input, pos)

      raise LexerError.unexpected_character(<<byte>>, line, col)
    end

    {type, value, opts} = build_word(parts)
    raw_value = Keyword.get(opts, :raw_value, value)

    token = %Token{
      type: type,
      value: value,
      raw_value: raw_value,
      start: pos,
      end: end_pos,
      line: line,
      column: col,
      quoted: Keyword.get(opts, :quoted, false),
      single_quoted: Keyword.get(opts, :single_quoted, false)
    }

    {new_line, new_col} = advance(raw_value, line, col)
    do_tokenize(input, end_pos, new_line, new_col, [token | acc], pending)
  end

  defp read_word(input, pos), do: do_read_word(input, pos, [])

  defp do_read_word(input, pos, parts) do
    case try_word_part(input, pos) do
      {part, new_pos} -> do_read_word(input, new_pos, [part | parts])
      nil -> {Enum.reverse(parts), pos}
    end
  end

  defp try_word_part(input, pos) when pos >= byte_size(input), do: nil

  defp try_word_part(input, pos) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?$ -> try_dollar_part(input, pos)
      byte == ?' -> read_sq(input, pos)
      byte == ?" -> read_dq(input, pos)
      byte == ?\\ and pos + 1 < byte_size(input) -> read_escape(input, pos)
      byte == ?` -> read_backtick(input, pos)
      byte == ?! and peek(input, pos + 1) == ?= -> {{:chars, "!="}, pos + 2}
      word_char?(byte) -> read_plain(input, pos)
      true -> nil
    end
  end

  defp try_dollar_part(input, pos) do
    case peek(input, pos + 1) do
      ?' ->
        read_ansi_c(input, pos)

      ?( ->
        if peek(input, pos + 2) == ?(,
          do: read_arith(input, pos),
          else: read_cmd_subst(input, pos)

      ?{ ->
        read_param_exp(input, pos)

      _ ->
        read_dollar_var(input, pos)
    end
  end

  # ── Word Part Readers ───────────────────────────────────────────────

  # Single-quoted string: '...'
  defp read_sq(input, pos) do
    end_pos = scan_to_byte(input, pos + 1, ?')

    if end_pos >= byte_size(input) do
      {line, col} = pos_to_line_col(input, pos)
      raise LexerError.unterminated(:single_quote, line, col)
    end

    content = binary_part(input, pos + 1, end_pos - pos - 1)
    {{:single_quoted, content}, end_pos + 1}
  end

  # Double-quoted string: "..."
  # Returns raw text including outer quotes for downstream expansion.
  defp read_dq(input, pos) do
    end_pos = find_close_dq(input, pos + 1)

    if end_pos >= byte_size(input) do
      {line, col} = pos_to_line_col(input, pos)
      raise LexerError.unterminated(:double_quote, line, col)
    end

    raw = binary_part(input, pos, end_pos + 1 - pos)
    {{:double_quoted, raw}, end_pos + 1}
  end

  defp find_close_dq(input, pos) when pos >= byte_size(input), do: pos

  defp find_close_dq(input, pos) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?" ->
        pos

      byte == ?\\ and pos + 1 < byte_size(input) ->
        find_close_dq(input, pos + 2)

      byte == ?$ and peek(input, pos + 1) == ?( and peek(input, pos + 2) == ?( ->
        find_close_dq(input, skip_to_close_double_paren(input, pos + 3, pos))

      byte == ?$ and peek(input, pos + 1) == ?( ->
        find_close_dq(input, skip_balanced(input, pos + 2, ?(, ?)))

      byte == ?$ and peek(input, pos + 1) == ?{ ->
        find_close_dq(input, skip_balanced(input, pos + 2, ?{, ?}))

      byte == ?` ->
        find_close_dq(input, skip_past_backtick(input, pos + 1))

      true ->
        find_close_dq(input, pos + 1)
    end
  end

  # ANSI-C quoted string: $'...'
  defp read_ansi_c(input, pos) do
    {content, close_pos} = read_ansi_c_content(input, pos + 2, [])
    {{:ansi_c_quoted, content}, close_pos + 1}
  end

  defp read_ansi_c_content(input, pos, acc) do
    cond do
      pos >= byte_size(input) ->
        {IO.iodata_to_binary(Enum.reverse(acc)), pos}

      :binary.at(input, pos) == ?' ->
        {IO.iodata_to_binary(Enum.reverse(acc)), pos}

      :binary.at(input, pos) == ?\\ ->
        read_ansi_c_escape(input, pos + 1, acc)

      true ->
        {char, next} = read_utf8_char(input, pos)
        read_ansi_c_content(input, next, [char | acc])
    end
  end

  defp read_ansi_c_escape(input, pos, acc) when pos >= byte_size(input) do
    read_ansi_c_content(input, pos, acc)
  end

  defp read_ansi_c_escape(input, pos, acc) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?x ->
        {val, end_pos} = read_hex_value(input, pos + 1, 0, 0)
        read_ansi_c_content(input, end_pos, [<<val>> | acc])

      byte in ?0..?7 ->
        {val, end_pos} = read_octal_value(input, pos, 0, 0)
        read_ansi_c_content(input, end_pos, [<<val>> | acc])

      true ->
        interpreted = Map.get(@ansi_c_escape_map, byte, <<byte::utf8>>)
        read_ansi_c_content(input, pos + 1, [interpreted | acc])
    end
  end

  defp read_hex_value(_input, pos, val, count) when count >= 2, do: {val, pos}
  defp read_hex_value(input, pos, val, _count) when pos >= byte_size(input), do: {val, pos}

  defp read_hex_value(input, pos, val, count) do
    byte = :binary.at(input, pos)

    cond do
      byte in ?0..?9 -> read_hex_value(input, pos + 1, val * 16 + (byte - ?0), count + 1)
      byte in ?a..?f -> read_hex_value(input, pos + 1, val * 16 + (byte - ?a + 10), count + 1)
      byte in ?A..?F -> read_hex_value(input, pos + 1, val * 16 + (byte - ?A + 10), count + 1)
      true -> {val, pos}
    end
  end

  defp read_octal_value(_input, pos, val, count) when count >= 3, do: {val, pos}
  defp read_octal_value(input, pos, val, _count) when pos >= byte_size(input), do: {val, pos}

  defp read_octal_value(input, pos, val, count) do
    byte = :binary.at(input, pos)

    if byte in ?0..?7 do
      read_octal_value(input, pos + 1, val * 8 + (byte - ?0), count + 1)
    else
      {val, pos}
    end
  end

  # Escape sequence outside quotes: \x
  defp read_escape(input, pos) do
    {char, next} = read_utf8_char(input, pos + 1)
    {{:escaped, "\\" <> char}, next}
  end

  # Arithmetic expansion: $((...))
  defp read_arith(input, pos) do
    end_pos = skip_to_close_double_paren(input, pos + 3, pos)
    raw = binary_part(input, pos, end_pos - pos)
    {{:chars, raw}, end_pos}
  end

  # Command substitution: $(...)
  defp read_cmd_subst(input, pos) do
    end_pos = skip_balanced(input, pos + 2, ?(, ?), {:command_substitution, pos})
    raw = binary_part(input, pos, end_pos - pos)
    {{:chars, raw}, end_pos}
  end

  # Parameter expansion: ${...}
  defp read_param_exp(input, pos) do
    end_pos = skip_balanced(input, pos + 2, ?{, ?}, {:parameter_expansion, pos})
    raw = binary_part(input, pos, end_pos - pos)
    {{:chars, raw}, end_pos}
  end

  # Backtick command substitution: `...`
  defp read_backtick(input, pos) do
    end_pos = find_close_backtick(input, pos + 1, pos)
    raw = binary_part(input, pos, end_pos + 1 - pos)
    {{:chars, raw}, end_pos + 1}
  end

  defp find_close_backtick(input, pos, open_pos) when pos >= byte_size(input) do
    {line, col} = pos_to_line_col(input, open_pos)
    raise LexerError.unterminated(:backtick, line, col)
  end

  defp find_close_backtick(input, pos, open_pos) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?` -> pos
      byte == ?\\ and pos + 1 < byte_size(input) -> find_close_backtick(input, pos + 2, open_pos)
      true -> find_close_backtick(input, pos + 1, open_pos)
    end
  end

  # Dollar variable: $VAR, $?, $$, etc.
  #
  # Special variables ($?, $$, $#, $!, $@, $*, $-, $0-$9) consume exactly
  # one character after `$`. Regular variables consume [a-zA-Z_][a-zA-Z0-9_]*.
  # A bare `$` at EOF or before a non-variable character produces just "$".
  @special_var_chars [??, ?$, ?#, ?@, ?*, ?!, ?-]

  defp read_dollar_var(input, pos) do
    next = pos + 1

    if next >= byte_size(input) do
      {{:chars, "$"}, next}
    else
      byte = :binary.at(input, next)

      cond do
        byte in @special_var_chars ->
          {{:chars, binary_part(input, pos, 2)}, next + 1}

        byte >= ?0 and byte <= ?9 ->
          {{:chars, binary_part(input, pos, 2)}, next + 1}

        ident_start?(byte) ->
          end_pos = read_ident_tail(input, next + 1)
          {{:chars, binary_part(input, pos, end_pos - pos)}, end_pos}

        true ->
          {{:chars, "$"}, next}
      end
    end
  end

  defp ident_start?(b), do: (b >= ?a and b <= ?z) or (b >= ?A and b <= ?Z) or b == ?_

  defp read_ident_tail(input, pos) when pos >= byte_size(input), do: pos

  defp read_ident_tail(input, pos) do
    byte = :binary.at(input, pos)

    if ident_start?(byte) or (byte >= ?0 and byte <= ?9) do
      read_ident_tail(input, pos + 1)
    else
      pos
    end
  end

  # Plain word characters (no special meaning)
  defp read_plain(input, pos), do: do_read_plain(input, pos, pos)

  defp do_read_plain(input, start, pos) when pos >= byte_size(input) do
    {{:chars, binary_part(input, start, pos - start)}, pos}
  end

  defp do_read_plain(input, start, pos) do
    if word_char?(:binary.at(input, pos)) do
      do_read_plain(input, start, pos + 1)
    else
      {{:chars, binary_part(input, start, pos - start)}, pos}
    end
  end

  # ── Balanced Delimiter Skipping ─────────────────────────────────────

  # Internal callers (skip_past_dq, find_close_dq) pass no context — they
  # tolerate hitting EOF because their own caller handles the error.
  defp skip_balanced(input, pos, open, close) do
    do_skip_balanced(input, pos, open, close, 1, nil)
  end

  # Top-level callers (read_cmd_subst, read_param_exp) pass {context, open_pos}
  # so we can raise a specific error with position on unterminated input or excessive depth.
  defp skip_balanced(input, pos, open, close, context) do
    do_skip_balanced(input, pos, open, close, 1, context)
  end

  defp do_skip_balanced(input, pos, _open, _close, _depth, context)
       when pos >= byte_size(input) do
    case context do
      {construct, open_pos} ->
        {line, col} = pos_to_line_col(input, open_pos)
        raise LexerError.unterminated(construct, line, col)

      nil ->
        pos
    end
  end

  defp do_skip_balanced(input, _pos, _open, _close, depth, context)
       when depth > @max_nesting_depth do
    case context do
      {construct, open_pos} ->
        {line, col} = pos_to_line_col(input, open_pos)
        raise LexerError.nesting_depth(construct, line, col)

      nil ->
        raise LexerError.nesting_depth(:expression)
    end
  end

  defp do_skip_balanced(input, pos, open, close, depth, context) do
    byte = :binary.at(input, pos)

    cond do
      byte == close and depth == 1 ->
        pos + 1

      byte == close ->
        do_skip_balanced(input, pos + 1, open, close, depth - 1, context)

      byte == open ->
        do_skip_balanced(input, pos + 1, open, close, depth + 1, context)

      byte == ?' ->
        do_skip_balanced(input, skip_past_sq(input, pos + 1), open, close, depth, context)

      byte == ?" ->
        do_skip_balanced(input, skip_past_dq(input, pos + 1), open, close, depth, context)

      byte == ?\\ and pos + 1 < byte_size(input) ->
        do_skip_balanced(input, pos + 2, open, close, depth, context)

      true ->
        do_skip_balanced(input, pos + 1, open, close, depth, context)
    end
  end

  defp skip_to_close_double_paren(input, pos, open_pos) when pos >= byte_size(input) do
    {line, col} = pos_to_line_col(input, open_pos)
    raise LexerError.unterminated(:arithmetic, line, col)
  end

  defp skip_to_close_double_paren(input, pos, open_pos) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?) and peek(input, pos + 1) == ?) ->
        pos + 2

      byte == ?( ->
        skip_to_close_double_paren(input, skip_balanced(input, pos + 1, ?(, ?)), open_pos)

      true ->
        skip_to_close_double_paren(input, pos + 1, open_pos)
    end
  end

  # Skip past a single-quoted string (pos is after the opening ')
  defp skip_past_sq(input, pos) when pos >= byte_size(input), do: pos

  defp skip_past_sq(input, pos) do
    if :binary.at(input, pos) == ?', do: pos + 1, else: skip_past_sq(input, pos + 1)
  end

  # Skip past a double-quoted string (pos is after the opening ")
  defp skip_past_dq(input, pos) when pos >= byte_size(input), do: pos

  defp skip_past_dq(input, pos) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?" ->
        pos + 1

      byte == ?\\ and pos + 1 < byte_size(input) ->
        skip_past_dq(input, pos + 2)

      byte == ?$ and peek(input, pos + 1) == ?( ->
        skip_past_dq(input, skip_balanced(input, pos + 2, ?(, ?)))

      byte == ?$ and peek(input, pos + 1) == ?{ ->
        skip_past_dq(input, skip_balanced(input, pos + 2, ?{, ?}))

      byte == ?` ->
        skip_past_dq(input, skip_past_backtick(input, pos + 1))

      true ->
        skip_past_dq(input, pos + 1)
    end
  end

  # Skip past a backtick string, handling \` escapes (pos is after the opening `)
  defp skip_past_backtick(input, pos) when pos >= byte_size(input), do: pos

  defp skip_past_backtick(input, pos) do
    byte = :binary.at(input, pos)

    cond do
      byte == ?` -> pos + 1
      byte == ?\\ and pos + 1 < byte_size(input) -> skip_past_backtick(input, pos + 2)
      true -> skip_past_backtick(input, pos + 1)
    end
  end

  # ── Heredoc ─────────────────────────────────────────────────────────

  defp read_heredoc_delim_and_continue(input, pos, line, col, acc, pending, op_type) do
    strip_tabs = op_type == :dlessdash
    {pos, line, col} = skip_ws(input, pos, line, col)
    {parts, end_pos} = read_word(input, pos)

    if parts == [] do
      raise LexerError.expected_delimiter(line, col)
    end

    {type, value, opts} = build_word(parts)
    raw_value = Keyword.get(opts, :raw_value, value)
    quoted = Keyword.get(opts, :quoted, false)
    single_quoted = Keyword.get(opts, :single_quoted, false)

    token = %Token{
      type: type,
      value: value,
      raw_value: raw_value,
      start: pos,
      end: end_pos,
      line: line,
      column: col,
      quoted: quoted,
      single_quoted: single_quoted
    }

    heredoc = %{delimiter: value, strip_tabs: strip_tabs, quoted: quoted || single_quoted}
    {new_line, new_col} = advance(raw_value, line, col)
    do_tokenize(input, end_pos, new_line, new_col, [token | acc], [heredoc | pending])
  end

  defp consume_heredocs(input, pos, line, pending) do
    do_consume_heredocs(input, pos, line, Enum.reverse(pending), [])
  end

  defp do_consume_heredocs(_input, pos, line, [], acc), do: {acc, pos, line}

  defp do_consume_heredocs(input, pos, line, [heredoc | rest], acc) do
    {content, new_pos, new_line} = read_heredoc_body(input, pos, line, heredoc)

    token = %Token{
      type: :heredoc_content,
      value: content,
      start: pos,
      end: new_pos,
      line: 0,
      column: 0
    }

    do_consume_heredocs(input, new_pos, new_line, rest, [token | acc])
  end

  defp read_heredoc_body(input, pos, line, heredoc) do
    do_read_heredoc_body(input, pos, line, heredoc.delimiter, heredoc.strip_tabs, [])
  end

  defp do_read_heredoc_body(input, pos, line, delimiter, strip_tabs, acc) do
    if pos >= byte_size(input) do
      {IO.iodata_to_binary(Enum.reverse(acc)), pos, line}
    else
      {raw_line, nl_pos} = read_line_at(input, pos)
      processed = if strip_tabs, do: String.replace(raw_line, @leading_tabs, ""), else: raw_line

      if processed == delimiter do
        next_pos = if nl_pos < byte_size(input), do: nl_pos + 1, else: nl_pos
        {IO.iodata_to_binary(Enum.reverse(acc)), next_pos, line + 1}
      else
        has_nl = nl_pos < byte_size(input) and :binary.at(input, nl_pos) == ?\n
        acc = if has_nl, do: ["\n", processed | acc], else: [processed | acc]
        next_pos = if has_nl, do: nl_pos + 1, else: nl_pos
        do_read_heredoc_body(input, next_pos, line + 1, delimiter, strip_tabs, acc)
      end
    end
  end

  defp read_line_at(input, pos), do: do_read_line_at(input, pos, pos)

  defp do_read_line_at(input, start, pos) do
    cond do
      pos >= byte_size(input) -> {binary_part(input, start, pos - start), pos}
      :binary.at(input, pos) == ?\n -> {binary_part(input, start, pos - start), pos}
      true -> do_read_line_at(input, start, pos + 1)
    end
  end

  # ── Word Classification ─────────────────────────────────────────────

  defp build_word(parts) do
    starts_quoted =
      match?([{:single_quoted, _} | _], parts) or
        match?([{:double_quoted, _} | _], parts) or
        match?([{:ansi_c_quoted, _} | _], parts)

    {value, raw_value, _has_quotes, single_quoted} =
      Enum.reduce(parts, {"", "", false, false}, fn
        {:chars, s}, {acc, raw, hq, sq} ->
          {acc <> s, raw <> s, hq, sq}

        {:single_quoted, s}, {acc, raw, _hq, _sq} ->
          {acc <> s, raw <> "'" <> s <> "'", true, true}

        {:ansi_c_quoted, s}, {acc, raw, _hq, _sq} ->
          {acc <> s, raw <> "$'" <> escape_for_raw(s) <> "'", true, false}

        {:double_quoted, s}, {acc, raw, _hq, sq} ->
          inner = String.slice(s, 1..-2//1)
          {acc <> inner, raw <> s, true, sq}

        {:escaped, s}, {acc, raw, hq, sq} ->
          interpreted = interpret_escape(s)
          {acc <> interpreted, raw <> s, hq, sq}
      end)

    quoted = starts_quoted
    single_quoted = starts_quoted and single_quoted

    type = classify_word(value, raw_value, quoted)
    {type, value, quoted: quoted, single_quoted: single_quoted, raw_value: raw_value}
  end

  defp escape_for_raw(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
    |> String.replace("'", "\\'")
  end

  defp interpret_escape(<<_backslash::utf8, rest::binary>>), do: rest
  defp interpret_escape(s), do: s

  defp classify_word(_value, _raw, true), do: :word

  defp classify_word(value, raw_value, false) do
    cond do
      value in @reserved -> String.to_existing_atom(value)
      assignment?(raw_value) -> :assignment_word
      all_digits?(value) -> :number
      name?(value) -> :name
      true -> :word
    end
  end

  defp all_digits?(<<c, rest::binary>>) when c >= ?0 and c <= ?9, do: all_digits?(rest)
  defp all_digits?(<<>>), do: true
  defp all_digits?(_), do: false

  defp name?(<<c, rest::binary>>)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ do
    name_tail?(rest)
  end

  defp name?(_), do: false

  defp name_tail?(<<c, rest::binary>>)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_ do
    name_tail?(rest)
  end

  defp name_tail?(<<>>), do: true
  defp name_tail?(_), do: false

  @assignment_lhs ~r/^[a-zA-Z_][a-zA-Z0-9_]*(\[[^\]]*\])?\+?$/

  defp assignment?(value) do
    case String.split(value, "=", parts: 2) do
      [lhs, _rhs] -> Regex.match?(@assignment_lhs, lhs)
      _ -> false
    end
  end

  # ── Character Classification ────────────────────────────────────────

  @special_chars [?\s, ?\t, ?\n, ?;, ?&, ?|, ?(, ?), ?{, ?}, ?<, ?>, ?#, ?', ?", ?\\, ?$, ?!, ?`]

  defp word_char?(b), do: b not in @special_chars

  # ── Utility ─────────────────────────────────────────────────────────

  defp mk(type, raw, pos, line, col) do
    %Token{
      type: type,
      value: raw,
      raw_value: raw,
      start: pos,
      end: pos + byte_size(raw),
      line: line,
      column: col
    }
  end

  defp skip_ws(input, pos, line, col) when pos >= byte_size(input), do: {pos, line, col}

  defp skip_ws(input, pos, line, col) do
    case :binary.at(input, pos) do
      c when c in [?\s, ?\t] ->
        skip_ws(input, pos + 1, line, col + 1)

      ?\\ ->
        if pos + 1 < byte_size(input) and :binary.at(input, pos + 1) == ?\n do
          skip_ws(input, pos + 2, line + 1, 1)
        else
          {pos, line, col}
        end

      _ ->
        {pos, line, col}
    end
  end

  defp advance(<<?\n, rest::binary>>, line, _col), do: advance(rest, line + 1, 1)
  defp advance(<<_, rest::binary>>, line, col), do: advance(rest, line, col + 1)
  defp advance(<<>>, line, col), do: {line, col}

  defp peek(input, pos) when pos >= byte_size(input), do: nil
  defp peek(input, pos), do: :binary.at(input, pos)

  # Compute line:col for a byte position by scanning from the start.
  # Only used on error paths, so O(n) cost is acceptable.
  defp pos_to_line_col(input, target_pos) do
    do_pos_to_line_col(input, 0, 1, 1, target_pos)
  end

  defp do_pos_to_line_col(_input, pos, line, col, target) when pos >= target, do: {line, col}

  defp do_pos_to_line_col(input, pos, line, col, target) when pos < byte_size(input) do
    if :binary.at(input, pos) == ?\n do
      do_pos_to_line_col(input, pos + 1, line + 1, 1, target)
    else
      do_pos_to_line_col(input, pos + 1, line, col + 1, target)
    end
  end

  defp do_pos_to_line_col(_input, _pos, line, col, _target), do: {line, col}

  defp scan_to_byte(input, pos, byte) do
    cond do
      pos >= byte_size(input) -> pos
      :binary.at(input, pos) == byte -> pos
      true -> scan_to_byte(input, pos + 1, byte)
    end
  end

  defp scan_to_newline(input, pos) do
    cond do
      pos >= byte_size(input) -> pos
      :binary.at(input, pos) == ?\n -> pos
      true -> scan_to_newline(input, pos + 1)
    end
  end

  defp read_utf8_char(input, pos) when pos >= byte_size(input), do: {"", pos}

  defp read_utf8_char(input, pos) do
    byte = :binary.at(input, pos)
    char_size = utf8_char_size(byte)
    actual_size = min(char_size, byte_size(input) - pos)
    {binary_part(input, pos, actual_size), pos + actual_size}
  end

  defp utf8_char_size(byte) when byte < 0x80, do: 1
  defp utf8_char_size(byte) when byte < 0xE0, do: 2
  defp utf8_char_size(byte) when byte < 0xF0, do: 3
  defp utf8_char_size(_byte), do: 4
end
