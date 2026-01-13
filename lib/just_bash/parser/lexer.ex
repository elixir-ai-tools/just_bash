defmodule JustBash.Parser.Lexer do
  @moduledoc """
  NimbleParsec-based Lexer for Bash Scripts

  A declarative, idiomatic Elixir lexer using parser combinators.
  Handles operators, keywords, words with quoting, heredocs, and more.
  """

  import NimbleParsec

  defmodule Token do
    @moduledoc "A lexer token with position information"
    defstruct [:type, :value, :start, :end, :line, :column, quoted: false, single_quoted: false]

    @type token_type ::
            :eof
            | :newline
            | :semicolon
            | :amp
            | :pipe
            | :pipe_amp
            | :and_and
            | :or_or
            | :bang
            | :less
            | :great
            | :dless
            | :dgreat
            | :lessand
            | :greatand
            | :lessgreat
            | :dlessdash
            | :clobber
            | :tless
            | :and_great
            | :and_dgreat
            | :lparen
            | :rparen
            | :lbrace
            | :rbrace
            | :dsemi
            | :semi_and
            | :semi_semi_and
            | :dbrack_start
            | :dbrack_end
            | :dparen_start
            | :dparen_end
            | :if
            | :then
            | :else
            | :elif
            | :fi
            | :for
            | :while
            | :until
            | :do
            | :done
            | :case
            | :esac
            | :in
            | :function
            | :select
            | :time
            | :coproc
            | :word
            | :name
            | :number
            | :assignment_word
            | :comment
            | :heredoc_content

    @type t :: %__MODULE__{
            type: token_type(),
            value: String.t(),
            start: non_neg_integer(),
            end: non_neg_integer(),
            line: pos_integer(),
            column: pos_integer(),
            quoted: boolean(),
            single_quoted: boolean()
          }
  end

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

  # In double quotes, only certain escapes are processed
  # \\ -> \, \" -> ", \n stays as \n (not newline)
  # IMPORTANT: \$ and \` must be preserved as-is so word_parts can recognize them as escaped
  # If we convert \$ to $ here, word_parts will interpret it as a variable expansion
  def build_dq_escape(["\\", c]) when c == ?\\ or c == ?" do
    <<c::utf8>>
  end

  # Preserve \$ and \` for word_parts to handle
  def build_dq_escape(["\\", c]) when c == ?$ or c == ?` do
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
      match?([{:single_quoted, _} | _], parts) or match?([{:double_quoted, _} | _], parts)

    {value, raw_value, _has_quotes, single_quoted} =
      Enum.reduce(parts, {"", "", false, false}, fn
        {:chars, s}, {acc, raw, hq, sq} ->
          {acc <> s, raw <> s, hq, sq}

        {:single_quoted, s}, {acc, raw, _hq, _sq} ->
          {acc <> s, raw <> "'" <> s <> "'", true, true}

        {:double_quoted, s}, {acc, raw, _hq, sq} ->
          # s already includes the quotes from build_double_quoted
          inner = String.slice(s, 1..-2//1)
          {acc <> inner, raw <> s, true, sq}

        {:escaped, s}, {acc, raw, hq, sq} ->
          {acc <> s, raw <> s, hq, sq}
      end)

    quoted = starts_quoted
    single_quoted = starts_quoted and single_quoted

    type = classify_word(value, raw_value, quoted)
    {type, value, quoted: quoted, single_quoted: single_quoted}
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
      [lhs, _rhs] -> Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*\+?$/, lhs)
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
        tokens = process_heredocs(tokens, input)
        tokens = process_brace_expansion(tokens)
        tokens ++ [eof_token(input)]

      {:error, msg, _rest, _ctx, {line, col}, _off} ->
        raise "Lexer error at #{line}:#{col}: #{msg}"
    end
  end

  # Post-process to handle brace expansion
  # Merge sequences like: [word?, lbrace, word, rbrace, word?] into a single word
  # when the content contains , or ..
  defp process_brace_expansion(tokens) do
    process_brace_expansion_loop(tokens, [])
  end

  defp process_brace_expansion_loop([], acc), do: Enum.reverse(acc)

  defp process_brace_expansion_loop([%Token{type: :lbrace} = lbrace | rest], acc) do
    case try_merge_brace_expansion(rest, lbrace, acc) do
      {:merged, new_token, remaining, new_acc} ->
        process_brace_expansion_loop(remaining, [new_token | new_acc])

      :not_brace_expansion ->
        process_brace_expansion_loop(rest, [lbrace | acc])
    end
  end

  defp process_brace_expansion_loop([token | rest], acc) do
    process_brace_expansion_loop(rest, [token | acc])
  end

  defp try_merge_brace_expansion(tokens, lbrace, acc) do
    case collect_brace_content(tokens, 1, []) do
      {:ok, content_tokens, rbrace, remaining} ->
        content = Enum.map_join(content_tokens, "", & &1.value)
        merged_value = "{" <> content <> "}"
        {prefix_token, new_acc} = extract_prefix_token(acc, lbrace)
        {suffix_token, final_remaining} = extract_suffix_token(remaining, rbrace)

        maybe_build_merged_token(
          content,
          merged_value,
          prefix_token,
          suffix_token,
          lbrace,
          rbrace,
          final_remaining,
          new_acc
        )

      :error ->
        :not_brace_expansion
    end
  end

  defp extract_prefix_token(acc, lbrace) do
    case acc do
      [%Token{type: t} = prev | rest]
      when t in [:word, :name, :number] and prev.end == lbrace.start ->
        {prev, rest}

      _ ->
        {nil, acc}
    end
  end

  defp extract_suffix_token(remaining, rbrace) do
    case remaining do
      [%Token{type: t} = next | rest]
      when t in [:word, :name, :number] and rbrace.end == next.start ->
        {next, rest}

      _ ->
        {nil, remaining}
    end
  end

  defp maybe_build_merged_token(
         content,
         merged_value,
         prefix_token,
         suffix_token,
         lbrace,
         rbrace,
         final_remaining,
         new_acc
       ) do
    has_adjacent = prefix_token != nil or suffix_token != nil
    is_brace_exp = brace_expansion_content?(content)
    is_word_like = not String.contains?(content, " ") and not String.contains?(content, "\t")

    if has_adjacent or is_brace_exp or is_word_like do
      new_token =
        build_merged_brace_token(merged_value, prefix_token, suffix_token, lbrace, rbrace)

      {:merged, new_token, final_remaining, new_acc}
    else
      :not_brace_expansion
    end
  end

  defp build_merged_brace_token(merged_value, prefix_token, suffix_token, lbrace, rbrace) do
    prefix_value = if prefix_token, do: prefix_token.value, else: ""
    suffix_value = if suffix_token, do: suffix_token.value, else: ""
    final_value = prefix_value <> merged_value <> suffix_value

    %Token{
      type: :word,
      value: final_value,
      start: (prefix_token || lbrace).start,
      end: (suffix_token || rbrace).end,
      line: (prefix_token || lbrace).line,
      column: (prefix_token || lbrace).column,
      quoted: false,
      single_quoted: false
    }
  end

  defp collect_brace_content([], _depth, _acc), do: :error

  defp collect_brace_content([%Token{type: :rbrace} = rbrace | rest], 1, acc) do
    {:ok, Enum.reverse(acc), rbrace, rest}
  end

  defp collect_brace_content([%Token{type: :rbrace} = token | rest], depth, acc) do
    collect_brace_content(rest, depth - 1, [token | acc])
  end

  defp collect_brace_content([%Token{type: :lbrace} = token | rest], depth, acc) do
    collect_brace_content(rest, depth + 1, [token | acc])
  end

  defp collect_brace_content([%Token{type: type} | _rest], _depth, _acc)
       when type in [:newline, :semicolon, :pipe, :amp, :and_and, :or_or, :eof] do
    :error
  end

  defp collect_brace_content([token | rest], depth, acc) do
    collect_brace_content(rest, depth, [token | acc])
  end

  defp brace_expansion_content?(content) do
    String.contains?(content, ",") or String.contains?(content, "..")
  end

  # Post-process to handle heredocs
  # When we see << or <<- followed by a word, we need to:
  # 1. Record the delimiter
  # 2. After the next newline, consume content until delimiter
  defp process_heredocs(tokens, input) do
    {processed, _pending} = process_heredocs_loop(tokens, input, [], [])
    processed
  end

  defp process_heredocs_loop([], _input, acc, _pending) do
    {Enum.reverse(acc), []}
  end

  defp process_heredocs_loop([token | rest], input, acc, pending) do
    cond do
      # Heredoc start: << or <<-
      token.type in [:dless, :dlessdash] ->
        strip_tabs = token.type == :dlessdash

        case rest do
          [delim_token | rest2] when delim_token.type in [:word, :name] ->
            delimiter = delim_token.value
            heredoc = %{delimiter: delimiter, strip_tabs: strip_tabs, quoted: false}
            acc = [delim_token, token | acc]
            process_heredocs_loop(rest2, input, acc, [heredoc | pending])

          _ ->
            process_heredocs_loop(rest, input, [token | acc], pending)
        end

      # Newline - check for pending heredocs
      token.type == :newline and pending != [] ->
        acc = [token | acc]
        {heredoc_tokens, new_pos, _rest2} = consume_heredocs(pending, input, token.end, [])
        acc = heredoc_tokens ++ acc

        # Skip tokens that are now part of heredoc content
        rest_filtered = skip_consumed_tokens(rest, new_pos)
        process_heredocs_loop(rest_filtered, input, acc, [])

      true ->
        process_heredocs_loop(rest, input, [token | acc], pending)
    end
  end

  defp consume_heredocs([], _input, pos, acc), do: {acc, pos, []}

  defp consume_heredocs([heredoc | rest], input, pos, acc) do
    {content, new_pos} = read_heredoc_content(input, pos, heredoc)

    token = %Token{
      type: :heredoc_content,
      value: content,
      start: pos,
      end: new_pos,
      line: 0,
      column: 0
    }

    consume_heredocs(rest, input, new_pos, [token | acc])
  end

  defp read_heredoc_content(input, pos, heredoc) do
    read_heredoc_lines(input, pos, heredoc.delimiter, heredoc.strip_tabs, "")
  end

  defp read_heredoc_lines(input, pos, delimiter, strip_tabs, content) do
    if pos >= byte_size(input) do
      {content, pos}
    else
      {line, end_pos} = read_line_at(input, pos)
      line_to_check = maybe_strip_leading_tabs(line, strip_tabs)

      process_heredoc_line(
        input,
        pos,
        end_pos,
        delimiter,
        strip_tabs,
        content,
        line,
        line_to_check
      )
    end
  end

  defp maybe_strip_leading_tabs(line, true), do: String.replace(line, ~r/^\t+/, "")
  defp maybe_strip_leading_tabs(line, false), do: line

  defp process_heredoc_line(
         input,
         pos,
         _end_pos,
         delimiter,
         _strip_tabs,
         content,
         _line,
         line_to_check
       )
       when line_to_check == delimiter do
    new_pos = consume_line_and_newline(input, pos)
    {content, new_pos}
  end

  defp process_heredoc_line(
         input,
         _pos,
         end_pos,
         delimiter,
         strip_tabs,
         content,
         line,
         _line_to_check
       ) do
    new_content = append_line_with_newline(content, line, input, end_pos)
    new_pos = advance_past_newline(input, end_pos)
    read_heredoc_lines(input, new_pos, delimiter, strip_tabs, new_content)
  end

  defp append_line_with_newline(content, line, input, end_pos) do
    has_newline = end_pos < byte_size(input) and :binary.at(input, end_pos) == ?\n

    if has_newline do
      content <> line <> "\n"
    else
      content <> line
    end
  end

  defp advance_past_newline(input, end_pos) do
    if end_pos < byte_size(input), do: end_pos + 1, else: end_pos
  end

  defp read_line_at(input, pos) do
    read_line_at_loop(input, pos, pos)
  end

  defp read_line_at_loop(input, start, pos) do
    cond do
      pos >= byte_size(input) ->
        {binary_part(input, start, pos - start), pos}

      :binary.at(input, pos) == ?\n ->
        {binary_part(input, start, pos - start), pos}

      true ->
        read_line_at_loop(input, start, pos + 1)
    end
  end

  defp consume_line_and_newline(input, pos) do
    # Skip to end of line
    pos = skip_to_newline(input, pos)
    # Skip the newline itself
    if pos < byte_size(input) and :binary.at(input, pos) == ?\n, do: pos + 1, else: pos
  end

  defp skip_to_newline(input, pos) do
    cond do
      pos >= byte_size(input) -> pos
      :binary.at(input, pos) == ?\n -> pos
      true -> skip_to_newline(input, pos + 1)
    end
  end

  defp skip_consumed_tokens(tokens, end_pos) do
    Enum.drop_while(tokens, fn t -> t.start < end_pos end)
  end

  defp build_tokens([], _input, _line, _col, _offset, acc), do: Enum.reverse(acc)

  defp build_tokens([raw | rest], input, line, col, offset, acc) do
    {type, value, opts} = normalize(raw)
    {offset, line, col} = skip_whitespace(input, offset, line, col)

    token = %Token{
      type: type,
      value: value,
      start: offset,
      end: offset + byte_size(value),
      line: line,
      column: col,
      quoted: Keyword.get(opts, :quoted, false),
      single_quoted: Keyword.get(opts, :single_quoted, false)
    }

    {new_line, new_col} = advance(value, line, col)
    build_tokens(rest, input, new_line, new_col, offset + byte_size(value), [token | acc])
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

  defp eof_token(input) do
    {line, col} =
      input
      |> String.graphemes()
      |> Enum.reduce({1, 1}, fn
        "\n", {l, _} -> {l + 1, 1}
        _, {l, c} -> {l, c + 1}
      end)

    %Token{
      type: :eof,
      value: "",
      start: byte_size(input),
      end: byte_size(input),
      line: line,
      column: col
    }
  end
end
