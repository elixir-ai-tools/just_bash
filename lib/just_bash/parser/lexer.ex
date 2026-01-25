defmodule JustBash.Parser.Lexer do
  @moduledoc """
  NimbleParsec-based Lexer for Bash Scripts.

  A declarative, idiomatic Elixir lexer using parser combinators.
  Handles operators, keywords, words with quoting, heredocs, and more.

  Post-processing is delegated to submodules:
  - `Lexer.Token` - Token struct and helpers
  - `Lexer.Heredoc` - Heredoc content handling
  - `Lexer.BraceExpansion` - Brace expansion merging
  """

  import NimbleParsec

  alias __MODULE__.BraceExpansion
  alias __MODULE__.Heredoc
  alias __MODULE__.Token

  # Whitespace (spaces and tabs only - newlines are tokens)
  whitespace = ascii_string([?\s, ?\t], min: 1) |> ignore()

  # Line continuation (backslash-newline)
  line_continuation = string("\\\n") |> ignore()

  # Skip whitespace and line continuations
  skip_ws =
    repeat(choice([whitespace, line_continuation]))
    |> ignore()

  # Comments
  comment =
    string("#")
    |> utf8_string([not: ?\n], min: 0)
    |> reduce({:make_comment, []})

  # Newline
  newline = string("\n") |> replace({:newline, "\n"})

  # Three-character operators
  op3 =
    choice([
      string("<<-") |> replace({:dlessdash, "<<-"}),
      string(";;&") |> replace({:semi_semi_and, ";;&"}),
      string("<<<") |> replace({:tless, "<<<"}),
      string("&>>") |> replace({:and_dgreat, "&>>"})
    ])

  # Two-character operators
  # Note: (( and )) need special handling - only operators at command position
  op2 =
    choice([
      string("&&") |> replace({:and_and, "&&"}),
      string("||") |> replace({:or_or, "||"}),
      string("<<") |> replace({:dless, "<<"}),
      string(">>") |> replace({:dgreat, ">>"}),
      string("<&") |> replace({:lessand, "<&"}),
      string(">&") |> replace({:greatand, ">&"}),
      string("<>") |> replace({:lessgreat, "<>"}),
      string(">|") |> replace({:clobber, ">|"}),
      string("|&") |> replace({:pipe_amp, "|&"}),
      string(";;") |> replace({:dsemi, ";;"}),
      string(";&") |> replace({:semi_and, ";&"}),
      string("&>") |> replace({:and_great, "&>"}),
      string("[[") |> replace({:dbrack_start, "[["}),
      string("]]") |> replace({:dbrack_end, "]]"})
    ])

  # Standalone (( and )) - only match when not preceded by $
  # We handle this specially - these are matched before words
  dparen_start =
    lookahead_not(string("$"))
    |> string("((")
    |> replace({:dparen_start, "(("})

  dparen_end = string("))") |> replace({:dparen_end, "))"})

  # Single-char operators
  # Note: ! is only an operator when not followed by = (!=)
  op1 =
    choice([
      string("|") |> replace({:pipe, "|"}),
      string("&") |> replace({:amp, "&"}),
      string(";") |> replace({:semicolon, ";"}),
      string("(") |> replace({:lparen, "("}),
      string(")") |> replace({:rparen, ")"}),
      string("{") |> replace({:lbrace, "{"}),
      string("}") |> replace({:rbrace, "}"}),
      string("<") |> replace({:less, "<"}),
      string(">") |> replace({:great, ">"}),
      string("!") |> lookahead_not(string("=")) |> replace({:bang, "!"})
    ])

  operators = choice([op3, op2, dparen_start, dparen_end, op1])

  # ANSI-C quoted string $'...' - interprets escape sequences
  ansi_c_quoted =
    string("$'")
    |> concat(parsec(:ansi_c_content))
    |> string("'")
    |> reduce({:build_ansi_c_quoted, []})
    |> unwrap_and_tag(:ansi_c_quoted)

  # Hex digit for escape sequences
  hex_digit = ascii_char([?0..?9, ?a..?f, ?A..?F])
  # Octal digit for escape sequences
  octal_digit = ascii_char([?0..?7])

  # Content inside $'...' - handles escape sequences
  defcombinatorp(
    :ansi_c_content,
    repeat(
      choice([
        # Hex escape: \xNN (1-2 hex digits)
        string("\\x")
        |> concat(hex_digit)
        |> optional(hex_digit)
        |> reduce({:ansi_c_hex_escape, []}),
        # Octal escape: \NNN (1-3 octal digits)
        string("\\")
        |> concat(octal_digit)
        |> optional(octal_digit)
        |> optional(octal_digit)
        |> reduce({:ansi_c_octal_escape, []}),
        # Other escape sequences (single char after \)
        string("\\") |> utf8_char([]) |> reduce({:ansi_c_escape, []}),
        # Regular characters (not backslash or closing quote)
        utf8_char([{:not, ?\\}, {:not, ?'}])
      ])
    )
    |> reduce({:join_chars, []})
  )

  # Single-quoted string
  single_quoted =
    ignore(string("'"))
    |> utf8_string([not: ?'], min: 0)
    |> ignore(string("'"))
    |> unwrap_and_tag(:single_quoted)

  # Double-quoted string content - preserves internal content as-is
  # Handle any escape sequence (backslash followed by any char)
  dq_escape =
    string("\\")
    |> utf8_char([])
    |> reduce({:build_dq_escape, []})

  dq_char =
    choice([
      dq_escape,
      utf8_char([{:not, ?"}, {:not, ?\\}])
    ])

  double_quoted =
    string("\"")
    |> repeat(dq_char)
    |> string("\"")
    |> reduce({:build_double_quoted, []})
    |> unwrap_and_tag(:double_quoted)

  # Escape outside quotes - preserve the backslash
  escape_seq =
    string("\\")
    |> utf8_char([])
    |> reduce({:build_escape, []})
    |> unwrap_and_tag(:escaped)

  # Word characters - excludes operators and special chars
  # But we need to handle $ and ! specially
  non_special_word_char =
    utf8_char([
      {:not, ?\s},
      {:not, ?\t},
      {:not, ?\n},
      {:not, ?;},
      {:not, ?&},
      {:not, ?|},
      {:not, ?(},
      {:not, ?)},
      {:not, ?{},
      {:not, ?}},
      {:not, ?<},
      {:not, ?>},
      {:not, ?#},
      {:not, ?'},
      {:not, ?"},
      {:not, ?\\},
      {:not, ?$},
      {:not, ?!}
    ])

  # != as a word (for test expressions)
  not_equal_word =
    string("!=")
    |> reduce({:join_chars, []})

  # $ followed by word char (variable like $x) or special ($?, $$, etc)
  dollar_var =
    string("$")
    |> lookahead_not(choice([string("("), string("{")]))
    |> utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_, ??, ?$, ?#, ?@, ?*, ?!, ?-], min: 0)
    |> reduce({:join_chars, []})

  # Basic word char is either a non-special char, a dollar-var, or !=
  basic_word_char =
    choice([
      not_equal_word,
      dollar_var,
      non_special_word_char
    ])

  # $(...) command substitution - handles nested parens
  cmd_subst =
    string("$(")
    |> concat(parsec(:cmd_subst_content))
    |> string(")")
    |> reduce({:join_chars, []})
    |> unwrap_and_tag(:chars)

  # Content inside $() - handles nested parens
  defcombinatorp(
    :cmd_subst_content,
    repeat(
      choice([
        string("$(") |> concat(parsec(:cmd_subst_content)) |> string(")"),
        string("(") |> concat(parsec(:paren_content)) |> string(")"),
        utf8_char([{:not, ?(}, {:not, ?)}])
      ])
    )
    |> reduce({:join_chars, []})
  )

  # Content inside regular parens
  defcombinatorp(
    :paren_content,
    repeat(
      choice([
        string("(") |> concat(parsec(:paren_content)) |> string(")"),
        utf8_char([{:not, ?(}, {:not, ?)}])
      ])
    )
    |> reduce({:join_chars, []})
  )

  # $((...)) arithmetic expansion - handles nested parens
  arith_expansion =
    string("$((")
    |> concat(parsec(:arith_content))
    |> string("))")
    |> reduce({:join_chars, []})
    |> unwrap_and_tag(:chars)

  # Content inside $((...)) - handles nested parens
  defcombinatorp(
    :arith_content,
    repeat(
      choice([
        string("(") |> concat(parsec(:arith_paren_content)) |> string(")"),
        utf8_char([{:not, ?(}, {:not, ?)}])
      ])
    )
    |> reduce({:join_chars, []})
  )

  # Content inside nested parens within $((...))
  defcombinatorp(
    :arith_paren_content,
    repeat(
      choice([
        string("(") |> concat(parsec(:arith_paren_content)) |> string(")"),
        utf8_char([{:not, ?(}, {:not, ?)}])
      ])
    )
    |> reduce({:join_chars, []})
  )

  # ${...} parameter expansion - handles nested braces
  param_expansion =
    string("${")
    |> concat(parsec(:param_content))
    |> string("}")
    |> reduce({:join_chars, []})
    |> unwrap_and_tag(:chars)

  # Content inside ${...} - handles nested braces and nested ${}
  defcombinatorp(
    :param_content,
    repeat(
      choice([
        string("${") |> concat(parsec(:param_content)) |> string("}"),
        string("{") |> concat(parsec(:brace_content)) |> string("}"),
        utf8_char([{:not, ?{}, {:not, ?}}])
      ])
    )
    |> reduce({:join_chars, []})
  )

  # Content inside nested braces within ${}
  defcombinatorp(
    :brace_content,
    repeat(
      choice([
        string("{") |> concat(parsec(:brace_content)) |> string("}"),
        utf8_char([{:not, ?{}, {:not, ?}}])
      ])
    )
    |> reduce({:join_chars, []})
  )

  # `...` backtick command substitution
  backtick_subst =
    string("`")
    |> utf8_string([not: ?`], min: 0)
    |> string("`")
    |> reduce({:join_chars, []})
    |> unwrap_and_tag(:chars)

  # Plain word characters (no special chars)
  word_chars =
    times(basic_word_char, min: 1)
    |> reduce({:join_chars, []})
    |> unwrap_and_tag(:chars)

  # Word parts - order matters! More specific patterns first
  word_part =
    choice([
      ansi_c_quoted,
      single_quoted,
      double_quoted,
      escape_seq,
      arith_expansion,
      cmd_subst,
      param_expansion,
      backtick_subst,
      word_chars
    ])

  # Complete word
  word =
    times(word_part, min: 1)
    |> reduce({:build_word, []})

  # Single token
  token = choice([comment, newline, operators, word])

  # Full tokenizer
  defparsec(
    :do_tokenize,
    repeat(skip_ws |> concat(token))
    |> concat(skip_ws)
    |> eos()
  )

  # Reduce helpers
  def make_comment(["#" | rest]) do
    content = Enum.join(rest)
    {:comment, "#" <> content}
  end

  def join_chars(chars) do
    chars
    |> Enum.map(fn
      c when is_integer(c) -> <<c::utf8>>
      s when is_binary(s) -> s
    end)
    |> IO.iodata_to_binary()
  end

  def build_escape(["\\", c]) when is_integer(c), do: "\\" <> <<c::utf8>>
  def build_escape([c]) when is_integer(c), do: "\\" <> <<c::utf8>>

  # ANSI-C escape sequence interpretation
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

  def ansi_c_escape(["\\", c]) when is_integer(c) do
    Map.get(@ansi_c_escape_map, c, <<c::utf8>>)
  end

  def ansi_c_escape([c]) when is_integer(c), do: <<c::utf8>>

  # Handle hex escapes: \xNN
  def ansi_c_hex_escape(["\\x" | hex_digits]) do
    hex_str = Enum.map_join(hex_digits, &<<&1::utf8>>)
    <<String.to_integer(hex_str, 16)>>
  end

  # Handle octal escapes: \NNN
  def ansi_c_octal_escape(["\\", d1]) when is_integer(d1) do
    <<String.to_integer(<<d1::utf8>>, 8)>>
  end

  def ansi_c_octal_escape(["\\", d1, d2]) when is_integer(d1) and is_integer(d2) do
    <<String.to_integer(<<d1::utf8, d2::utf8>>, 8)>>
  end

  def ansi_c_octal_escape(["\\", d1, d2, d3])
      when is_integer(d1) and is_integer(d2) and is_integer(d3) do
    <<String.to_integer(<<d1::utf8, d2::utf8, d3::utf8>>, 8)>>
  end

  def build_ansi_c_quoted(["$'" | rest]) do
    # Last element is the closing quote, content is in between
    content = rest |> Enum.take(length(rest) - 1) |> join_chars()
    content
  end

  # Interpret an escape sequence outside quotes - strip the backslash
  # In bash, \X outside quotes becomes X (the backslash quotes the next character)
  defp interpret_escape(<<_backslash::utf8, rest::binary>>), do: rest
  defp interpret_escape(s), do: s

  # In double quotes, preserve escape sequences for word_parts to process
  # We need to keep \", \\, \$, \` so word_parts can handle them correctly
  # Only the final expansion phase should interpret these escapes
  def build_dq_escape(["\\", c]) when c == ?\\ or c == ?" or c == ?$ or c == ?` do
    "\\" <> <<c::utf8>>
  end

  def build_dq_escape(["\\", c]) when is_integer(c) do
    "\\" <> <<c::utf8>>
  end

  def build_dq_escape([c]) when is_integer(c), do: <<c::utf8>>

  def build_double_quoted(parts) do
    # Keep the full string including quotes for raw_value tracking
    parts
    |> Enum.map(fn
      c when is_integer(c) -> <<c::utf8>>
      s when is_binary(s) -> s
    end)
    |> IO.iodata_to_binary()
  end

  def build_word(parts) do
    # Build the display value and track original for assignment detection
    # quoted/single_quoted flags only true if word STARTS with a quote
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
          # s is already the interpreted content, raw needs $'...'
          {acc <> s, raw <> "$'" <> escape_for_raw(s) <> "'", true, false}

        {:double_quoted, s}, {acc, raw, _hq, sq} ->
          # s already includes the quotes from build_double_quoted
          inner = String.slice(s, 1..-2//1)
          {acc <> inner, raw <> s, true, sq}

        {:escaped, s}, {acc, raw, hq, sq} ->
          # Outside quotes, backslash escapes the next character
          # So \' becomes ', \\ becomes \, etc.
          interpreted = interpret_escape(s)
          {acc <> interpreted, raw <> s, hq, sq}
      end)

    quoted = starts_quoted
    single_quoted = starts_quoted and single_quoted

    type = classify_word(value, raw_value, quoted)
    {type, value, quoted: quoted, single_quoted: single_quoted, raw_value: raw_value}
  end

  # Escape special characters for raw_value reconstruction
  defp escape_for_raw(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
    |> String.replace("'", "\\'")
  end

  @reserved ~w(if then else elif fi for while until do done case esac in function select time coproc)

  defp classify_word(_value, _raw, true), do: :word

  defp classify_word(value, raw_value, false) do
    cond do
      value in @reserved -> String.to_atom(value)
      assignment?(raw_value) -> :assignment_word
      Regex.match?(~r/^[0-9]+$/, value) -> :number
      Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, value) -> :name
      true -> :word
    end
  end

  defp assignment?(value) do
    case String.split(value, "=", parts: 2) do
      # Match simple variable (foo=), append (foo+=), or array element (arr[n]=, arr[n]+=)
      [lhs, _rhs] -> Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(\[[^\]]*\])?\+?$/, lhs)
      _ -> false
    end
  end

  @doc """
  Tokenize input string into a list of tokens.
  """
  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(input) when is_binary(input) do
    case do_tokenize(input) do
      {:ok, raw_tokens, "", _, _, _} ->
        tokens = build_tokens(raw_tokens, input, 1, 1, 0, [])
        tokens = Heredoc.process(tokens, input)
        tokens = BraceExpansion.process(tokens)
        tokens ++ [Token.eof(input)]

      {:error, msg, _rest, _ctx, {line, col}, _off} ->
        raise "Lexer error at #{line}:#{col}: #{msg}"
    end
  end

  defp build_tokens([], _input, _line, _col, _offset, acc), do: Enum.reverse(acc)

  defp build_tokens([raw | rest], input, line, col, offset, acc) do
    {type, value, opts} = normalize(raw)
    {offset, line, col} = skip_whitespace(input, offset, line, col)

    raw_value = Keyword.get(opts, :raw_value, value)

    token = %Token{
      type: type,
      value: value,
      raw_value: raw_value,
      start: offset,
      end: offset + byte_size(raw_value),
      line: line,
      column: col,
      quoted: Keyword.get(opts, :quoted, false),
      single_quoted: Keyword.get(opts, :single_quoted, false)
    }

    {new_line, new_col} = advance(raw_value, line, col)
    build_tokens(rest, input, new_line, new_col, offset + byte_size(raw_value), [token | acc])
  end

  defp normalize({type, value}) when is_atom(type), do: {type, value, []}
  defp normalize({type, value, opts}), do: {type, value, opts}

  defp skip_whitespace(input, offset, line, col) when offset >= byte_size(input),
    do: {offset, line, col}

  defp skip_whitespace(input, offset, line, col) do
    case :binary.at(input, offset) do
      c when c in [?\s, ?\t] ->
        skip_whitespace(input, offset + 1, line, col + 1)

      ?\\ ->
        if offset + 1 < byte_size(input) and :binary.at(input, offset + 1) == ?\n do
          skip_whitespace(input, offset + 2, line + 1, 1)
        else
          {offset, line, col}
        end

      _ ->
        {offset, line, col}
    end
  end

  defp advance(value, line, col) do
    value
    |> String.graphemes()
    |> Enum.reduce({line, col}, fn
      "\n", {l, _} -> {l + 1, 1}
      _, {l, c} -> {l, c + 1}
    end)
  end
end
