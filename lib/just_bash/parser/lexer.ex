defmodule JustBash.Parser.Lexer do
  @moduledoc """
  Lexer for Bash Scripts

  The lexer tokenizes input into a stream of tokens that the parser consumes.
  It handles:
  - Operators and delimiters
  - Words (with quoting rules)
  - Comments
  - Here-documents
  - Escape sequences
  """

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

  @reserved_words %{
    "if" => :if,
    "then" => :then,
    "else" => :else,
    "elif" => :elif,
    "fi" => :fi,
    "for" => :for,
    "while" => :while,
    "until" => :until,
    "do" => :do,
    "done" => :done,
    "case" => :case,
    "esac" => :esac,
    "in" => :in,
    "function" => :function,
    "select" => :select,
    "time" => :time,
    "coproc" => :coproc
  }

  @single_char_ops %{
    ?| => :pipe,
    ?& => :amp,
    ?; => :semicolon,
    ?( => :lparen,
    ?) => :rparen,
    ?< => :less,
    ?> => :great
  }

  defstruct input: "",
            pos: 0,
            line: 1,
            column: 1,
            tokens: [],
            pending_heredocs: []

  @type t :: %__MODULE__{
          input: String.t(),
          pos: non_neg_integer(),
          line: pos_integer(),
          column: pos_integer(),
          tokens: [Token.t()],
          pending_heredocs: [%{delimiter: String.t(), strip_tabs: boolean(), quoted: boolean()}]
        }

  @doc """
  Tokenize the entire input string.
  """
  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(input) when is_binary(input) do
    lexer = %__MODULE__{input: input}
    do_tokenize(lexer)
  end

  defp do_tokenize(lexer) do
    lexer = skip_whitespace(lexer)

    if lexer.pos >= byte_size(lexer.input) do
      eof_token = %Token{
        type: :eof,
        value: "",
        start: lexer.pos,
        end: lexer.pos,
        line: lexer.line,
        column: lexer.column
      }

      Enum.reverse([eof_token | lexer.tokens])
    else
      lexer = maybe_read_heredoc_content(lexer)

      case next_token(lexer) do
        {nil, lexer} ->
          do_tokenize(lexer)

        {token, lexer} ->
          lexer = %{lexer | tokens: [token | lexer.tokens]}
          do_tokenize(lexer)
      end
    end
  end

  defp maybe_read_heredoc_content(lexer) do
    has_pending = lexer.pending_heredocs != []
    has_tokens = lexer.tokens != []
    last_is_newline = has_tokens and hd(lexer.tokens).type == :newline

    if has_pending and last_is_newline do
      read_heredoc_content(lexer)
    else
      lexer
    end
  end

  defp skip_whitespace(lexer) do
    c = char_at(lexer.input, lexer.pos)
    c_next = char_at(lexer.input, lexer.pos + 1)

    cond do
      c in [?\s, ?\t] ->
        skip_whitespace(%{lexer | pos: lexer.pos + 1, column: lexer.column + 1})

      c == ?\\ and c_next == ?\n ->
        skip_whitespace(%{lexer | pos: lexer.pos + 2, line: lexer.line + 1, column: 1})

      true ->
        lexer
    end
  end

  defp next_token(lexer) do
    input = lexer.input
    pos = lexer.pos
    start_line = lexer.line
    start_column = lexer.column
    c0 = char_at(input, pos)
    c1 = char_at(input, pos + 1)
    c2 = char_at(input, pos + 2)

    cond do
      c0 == ?# ->
        read_comment(lexer, pos, start_line, start_column)

      c0 == ?\n ->
        token = %Token{
          type: :newline,
          value: "\n",
          start: pos,
          end: pos + 1,
          line: start_line,
          column: start_column
        }

        {token, %{lexer | pos: pos + 1, line: lexer.line + 1, column: 1}}

      c0 == ?< and c1 == ?< and c2 == ?- ->
        lexer = %{lexer | pos: pos + 3, column: start_column + 3}
        lexer = register_heredoc_from_lookahead(lexer, true)
        token = make_token(:dlessdash, "<<-", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?; and c1 == ?; and c2 == ?& ->
        lexer = %{lexer | pos: pos + 3, column: start_column + 3}
        token = make_token(:semi_semi_and, ";;&", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?< and c1 == ?< and c2 == ?< ->
        lexer = %{lexer | pos: pos + 3, column: start_column + 3}
        token = make_token(:tless, "<<<", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?& and c1 == ?> and c2 == ?> ->
        lexer = %{lexer | pos: pos + 3, column: start_column + 3}
        token = make_token(:and_dgreat, "&>>", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?< and c1 == ?< ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        lexer = register_heredoc_from_lookahead(lexer, false)
        token = make_token(:dless, "<<", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?[ and c1 == ?[ ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:dbrack_start, "[[", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?] and c1 == ?] ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:dbrack_end, "]]", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?( and c1 == ?( ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:dparen_start, "((", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?) and c1 == ?) ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:dparen_end, "))", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?& and c1 == ?& ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:and_and, "&&", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?| and c1 == ?| ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:or_or, "||", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?; and c1 == ?; ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:dsemi, ";;", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?; and c1 == ?& ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:semi_and, ";&", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?| and c1 == ?& ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:pipe_amp, "|&", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?> and c1 == ?> ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:dgreat, ">>", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?< and c1 == ?& ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:lessand, "<&", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?> and c1 == ?& ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:greatand, ">&", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?< and c1 == ?> ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:lessgreat, "<>", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?> and c1 == ?| ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:clobber, ">|", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?& and c1 == ?> ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}
        token = make_token(:and_great, "&>", pos, lexer.pos, start_line, start_column)
        {token, lexer}

      Map.has_key?(@single_char_ops, c0) ->
        lexer = %{lexer | pos: pos + 1, column: start_column + 1}
        type = Map.fetch!(@single_char_ops, c0)
        token = make_token(type, <<c0>>, pos, lexer.pos, start_line, start_column)
        {token, lexer}

      c0 == ?{ ->
        handle_lbrace(lexer, pos, c1, start_line, start_column)

      c0 == ?} ->
        handle_rbrace(lexer, pos, start_line, start_column)

      c0 == ?! ->
        handle_bang(lexer, pos, c1, start_line, start_column)

      true ->
        read_word(lexer, pos, start_line, start_column)
    end
  end

  defp handle_lbrace(lexer, pos, c1, start_line, start_column) do
    cond do
      c1 == ?} ->
        lexer = %{lexer | pos: pos + 2, column: start_column + 2}

        token = %Token{
          type: :word,
          value: "{}",
          start: pos,
          end: pos + 2,
          line: start_line,
          column: start_column,
          quoted: false,
          single_quoted: false
        }

        {token, lexer}

      scan_brace_expansion(lexer.input, pos) != nil ->
        read_word_with_brace_expansion(lexer, pos, start_line, start_column)

      scan_literal_brace_word(lexer.input, pos) != nil ->
        read_word_with_brace_expansion(lexer, pos, start_line, start_column)

      c1 != nil and c1 not in [?\s, ?\t, ?\n] ->
        read_word(lexer, pos, start_line, start_column)

      true ->
        lexer = %{lexer | pos: pos + 1, column: start_column + 1}
        token = make_token(:lbrace, "{", pos, lexer.pos, start_line, start_column)
        {token, lexer}
    end
  end

  defp handle_rbrace(lexer, pos, start_line, start_column) do
    if is_word_char_following?(lexer.input, pos + 1) do
      read_word(lexer, pos, start_line, start_column)
    else
      lexer = %{lexer | pos: pos + 1, column: start_column + 1}
      token = make_token(:rbrace, "}", pos, lexer.pos, start_line, start_column)
      {token, lexer}
    end
  end

  defp handle_bang(lexer, pos, c1, start_line, start_column) do
    if c1 == ?= do
      lexer = %{lexer | pos: pos + 2, column: start_column + 2}
      token = make_token(:word, "!=", pos, lexer.pos, start_line, start_column)
      {token, lexer}
    else
      lexer = %{lexer | pos: pos + 1, column: start_column + 1}
      token = make_token(:bang, "!", pos, lexer.pos, start_line, start_column)
      {token, lexer}
    end
  end

  defp make_token(type, value, start, end_pos, line, column) do
    %Token{
      type: type,
      value: value,
      start: start,
      end: end_pos,
      line: line,
      column: column
    }
  end

  defp read_comment(lexer, start, line, column) do
    {end_pos, _} = read_until_newline(lexer.input, lexer.pos)
    value = binary_part(lexer.input, start, end_pos - start)

    token = %Token{
      type: :comment,
      value: value,
      start: start,
      end: end_pos,
      line: line,
      column: column
    }

    {token, %{lexer | pos: end_pos, column: column + (end_pos - start)}}
  end

  defp read_until_newline(input, pos) do
    case char_at(input, pos) do
      nil -> {pos, pos}
      ?\n -> {pos, pos}
      _ -> read_until_newline(input, pos + 1)
    end
  end

  defp read_word(lexer, start, line, column) do
    {value, lexer, quoted, single_quoted} = read_word_slow(lexer, start, line, column)

    cond do
      value == "" ->
        token = %Token{
          type: :word,
          value: "",
          start: start,
          end: lexer.pos,
          line: line,
          column: column,
          quoted: quoted,
          single_quoted: single_quoted
        }

        {token, lexer}

      not quoted and Map.has_key?(@reserved_words, value) ->
        type = Map.fetch!(@reserved_words, value)

        token = %Token{
          type: type,
          value: value,
          start: start,
          end: lexer.pos,
          line: line,
          column: column
        }

        {token, lexer}

      is_assignment?(value) ->
        token = %Token{
          type: :assignment_word,
          value: value,
          start: start,
          end: lexer.pos,
          line: line,
          column: column,
          quoted: quoted,
          single_quoted: single_quoted
        }

        {token, lexer}

      Regex.match?(~r/^[0-9]+$/, value) ->
        token = %Token{
          type: :number,
          value: value,
          start: start,
          end: lexer.pos,
          line: line,
          column: column
        }

        {token, lexer}

      is_valid_name?(value) ->
        token = %Token{
          type: :name,
          value: value,
          start: start,
          end: lexer.pos,
          line: line,
          column: column,
          quoted: quoted,
          single_quoted: single_quoted
        }

        {token, lexer}

      true ->
        token = %Token{
          type: :word,
          value: value,
          start: start,
          end: lexer.pos,
          line: line,
          column: column,
          quoted: quoted,
          single_quoted: single_quoted
        }

        {token, lexer}
    end
  end

  defp read_word_slow(lexer, _start, _line, _column) do
    input = lexer.input
    len = byte_size(input)
    pos = lexer.pos
    col = lexer.column
    ln = lexer.line
    starts_with_quote = char_at(input, pos) in [?", ?']

    {value, pos, col, ln, quoted, single_quoted} =
      read_word_loop(input, len, pos, col, ln, "", false, false, false, false, starts_with_quote)

    new_lexer = %{lexer | pos: pos, column: col, line: ln}
    {value, new_lexer, quoted, single_quoted}
  end

  defp read_word_loop(
         input,
         len,
         pos,
         col,
         ln,
         value,
         quoted,
         single_quoted,
         in_single_quote,
         in_double_quote,
         starts_with_quote
       ) do
    if pos >= len do
      {value, pos, col, ln, quoted, single_quoted}
    else
      char = char_at(input, pos)

      cond do
        not in_single_quote and not in_double_quote and
            char in [?\s, ?\t, ?\n, ?;, ?&, ?|, ?(, ?), ?<, ?>] ->
          {value, pos, col, ln, quoted, single_quoted}

        char == ?$ and char_at(input, pos + 1) == ?' and not in_single_quote and
            not in_double_quote ->
          {new_value, new_pos, new_col} = read_ansi_c_string(input, pos, col)

          read_word_loop(
            input,
            len,
            new_pos,
            new_col,
            ln,
            value <> new_value,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote
          )

        char == ?$ and char_at(input, pos + 1) == ?" and not in_single_quote and
            not in_double_quote ->
          new_starts_with_quote = if value == "", do: true, else: starts_with_quote

          read_word_loop(
            input,
            len,
            pos + 2,
            col + 2,
            ln,
            value,
            true,
            single_quoted,
            in_single_quote,
            true,
            new_starts_with_quote
          )

        char == ?' and not in_double_quote ->
          if in_single_quote do
            new_value = if not starts_with_quote, do: value <> "'", else: value

            read_word_loop(
              input,
              len,
              pos + 1,
              col + 1,
              ln,
              new_value,
              quoted,
              single_quoted,
              false,
              in_double_quote,
              starts_with_quote
            )
          else
            {new_single_quoted, new_quoted, new_value} =
              if starts_with_quote do
                {true, true, value}
              else
                {single_quoted, quoted, value <> "'"}
              end

            read_word_loop(
              input,
              len,
              pos + 1,
              col + 1,
              ln,
              new_value,
              new_quoted,
              new_single_quoted,
              true,
              in_double_quote,
              starts_with_quote
            )
          end

        char == ?" and not in_single_quote ->
          if in_double_quote do
            new_value = if not starts_with_quote, do: value <> "\"", else: value

            read_word_loop(
              input,
              len,
              pos + 1,
              col + 1,
              ln,
              new_value,
              quoted,
              single_quoted,
              in_single_quote,
              false,
              starts_with_quote
            )
          else
            {new_quoted, new_value} =
              if starts_with_quote do
                {true, value}
              else
                {quoted, value <> "\""}
              end

            read_word_loop(
              input,
              len,
              pos + 1,
              col + 1,
              ln,
              new_value,
              new_quoted,
              single_quoted,
              in_single_quote,
              true,
              starts_with_quote
            )
          end

        char == ?\\ and not in_single_quote and pos + 1 < len ->
          next_char = char_at(input, pos + 1)

          handle_escape(
            input,
            len,
            pos,
            col,
            ln,
            value,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote,
            next_char
          )

        char == ?$ and pos + 1 < len and char_at(input, pos + 1) == ?( ->
          {new_value, new_pos, new_col, new_ln} = read_command_substitution(input, pos, col, ln)

          read_word_loop(
            input,
            len,
            new_pos,
            new_col,
            new_ln,
            value <> new_value,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote
          )

        char == ?$ and pos + 1 < len and char_at(input, pos + 1) == ?[ ->
          {new_value, new_pos, new_col, new_ln} = read_old_arithmetic(input, pos, col, ln)

          read_word_loop(
            input,
            len,
            new_pos,
            new_col,
            new_ln,
            value <> new_value,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote
          )

        char == ?$ and pos + 1 < len and char_at(input, pos + 1) == ?{ ->
          {new_value, new_pos, new_col, new_ln} = read_parameter_expansion(input, pos, col, ln)

          read_word_loop(
            input,
            len,
            new_pos,
            new_col,
            new_ln,
            value <> new_value,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote
          )

        char == ?$ and pos + 1 < len and is_special_var?(char_at(input, pos + 1)) ->
          next = char_at(input, pos + 1)

          read_word_loop(
            input,
            len,
            pos + 2,
            col + 2,
            ln,
            value <> "$" <> <<next>>,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote
          )

        char == ?` ->
          {new_value, new_pos, new_col, new_ln} = read_backtick_substitution(input, pos, col, ln)

          read_word_loop(
            input,
            len,
            new_pos,
            new_col,
            new_ln,
            value <> new_value,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote
          )

        true ->
          {new_ln, new_col} = if char == ?\n, do: {ln + 1, 1}, else: {ln, col + 1}

          read_word_loop(
            input,
            len,
            pos + 1,
            new_col,
            new_ln,
            value <> <<char>>,
            quoted,
            single_quoted,
            in_single_quote,
            in_double_quote,
            starts_with_quote
          )
      end
    end
  end

  defp handle_escape(
         input,
         len,
         pos,
         col,
         ln,
         value,
         quoted,
         single_quoted,
         in_single_quote,
         in_double_quote,
         starts_with_quote,
         next_char
       ) do
    cond do
      next_char == ?\n ->
        read_word_loop(
          input,
          len,
          pos + 2,
          1,
          ln + 1,
          value,
          quoted,
          single_quoted,
          in_single_quote,
          in_double_quote,
          starts_with_quote
        )

      in_double_quote and next_char in [?", ?\\, ?$, ?`, ?\n] ->
        new_value =
          if next_char in [?$, ?`] do
            value <> "\\" <> <<next_char>>
          else
            value <> <<next_char>>
          end

        read_word_loop(
          input,
          len,
          pos + 2,
          col + 2,
          ln,
          new_value,
          quoted,
          single_quoted,
          in_single_quote,
          in_double_quote,
          starts_with_quote
        )

      not in_double_quote ->
        new_value =
          if next_char in [?", ?'] do
            value <> "\\" <> <<next_char>>
          else
            value <> <<next_char>>
          end

        read_word_loop(
          input,
          len,
          pos + 2,
          col + 2,
          ln,
          new_value,
          quoted,
          single_quoted,
          in_single_quote,
          in_double_quote,
          starts_with_quote
        )

      true ->
        read_word_loop(
          input,
          len,
          pos + 1,
          col + 1,
          ln,
          value <> "\\",
          quoted,
          single_quoted,
          in_single_quote,
          in_double_quote,
          starts_with_quote
        )
    end
  end

  defp read_ansi_c_string(input, pos, col) do
    value = "$'"
    pos = pos + 2
    col = col + 2

    read_ansi_c_loop(input, pos, col, value)
  end

  defp read_ansi_c_loop(input, pos, col, value) do
    c = char_at(input, pos)
    c_next = char_at(input, pos + 1)

    cond do
      c == nil ->
        {value, pos, col}

      c == ?' ->
        {value <> "'", pos + 1, col + 1}

      c == ?\\ and c_next != nil ->
        read_ansi_c_loop(input, pos + 2, col + 2, value <> "\\" <> <<c_next>>)

      true ->
        read_ansi_c_loop(input, pos + 1, col + 1, value <> <<c>>)
    end
  end

  defp read_command_substitution(input, pos, col, ln) do
    value = "$("
    pos = pos + 2
    col = col + 2

    read_nested_construct(input, pos, col, ln, value, ?(, ?))
  end

  defp read_old_arithmetic(input, pos, col, ln) do
    value = "$["
    pos = pos + 2
    col = col + 2

    read_nested_construct(input, pos, col, ln, value, ?[, ?])
  end

  defp read_parameter_expansion(input, pos, col, ln) do
    value = "${"
    pos = pos + 2
    col = col + 2

    read_nested_construct(input, pos, col, ln, value, ?{, ?})
  end

  defp read_nested_construct(input, pos, col, ln, value, open_char, close_char) do
    read_nested_loop(input, pos, col, ln, value, open_char, close_char, 1)
  end

  defp read_nested_loop(input, pos, col, ln, value, open_char, close_char, depth) do
    if depth == 0 or pos >= byte_size(input) do
      {value, pos, col, ln}
    else
      c = char_at(input, pos)

      {new_depth, new_value} =
        cond do
          c == open_char -> {depth + 1, value <> <<c>>}
          c == close_char -> {depth - 1, value <> <<c>>}
          true -> {depth, value <> <<c>>}
        end

      {new_ln, new_col} = if c == ?\n, do: {ln + 1, 1}, else: {ln, col + 1}

      read_nested_loop(
        input,
        pos + 1,
        new_col,
        new_ln,
        new_value,
        open_char,
        close_char,
        new_depth
      )
    end
  end

  defp read_backtick_substitution(input, pos, col, ln) do
    value = "`"
    pos = pos + 1
    col = col + 1

    read_backtick_loop(input, pos, col, ln, value)
  end

  defp read_backtick_loop(input, pos, col, ln, value) do
    c = char_at(input, pos)
    c_next = char_at(input, pos + 1)

    cond do
      c == nil ->
        {value, pos, col, ln}

      c == ?` ->
        {value <> "`", pos + 1, col + 1, ln}

      c == ?\\ and c_next != nil ->
        {new_ln, new_col} = if c_next == ?\n, do: {ln + 1, 1}, else: {ln, col + 2}
        read_backtick_loop(input, pos + 2, new_col, new_ln, value <> "\\" <> <<c_next>>)

      c == ?\n ->
        read_backtick_loop(input, pos + 1, 1, ln + 1, value <> "\n")

      true ->
        read_backtick_loop(input, pos + 1, col + 1, ln, value <> <<c>>)
    end
  end

  defp read_word_with_brace_expansion(lexer, start, line, column) do
    {end_pos, col} = scan_word_with_braces(lexer.input, start, column)
    value = binary_part(lexer.input, start, end_pos - start)

    token = %Token{
      type: :word,
      value: value,
      start: start,
      end: end_pos,
      line: line,
      column: column,
      quoted: false,
      single_quoted: false
    }

    {token, %{lexer | pos: end_pos, column: col}}
  end

  defp scan_word_with_braces(input, pos, col) do
    len = byte_size(input)
    scan_word_with_braces_loop(input, len, pos, col)
  end

  defp scan_word_with_braces_loop(input, len, pos, col) do
    if pos >= len do
      {pos, col}
    else
      c = char_at(input, pos)

      cond do
        c in [?\s, ?\t, ?\n, ?;, ?&, ?|, ?(, ?), ?<, ?>] ->
          {pos, col}

        c == ?{ ->
          case scan_brace_expansion(input, pos) do
            nil ->
              scan_word_with_braces_loop(input, len, pos + 1, col + 1)

            _ ->
              {end_pos, new_col} = consume_brace_expansion(input, pos + 1, col + 1, 1)
              scan_word_with_braces_loop(input, len, end_pos, new_col)
          end

        c == ?} ->
          scan_word_with_braces_loop(input, len, pos + 1, col + 1)

        c == ?$ and char_at(input, pos + 1) == ?( ->
          {end_pos, new_col} = consume_brace_expansion(input, pos + 2, col + 2, 1)
          scan_word_with_braces_loop(input, len, end_pos, new_col)

        c == ?$ and char_at(input, pos + 1) == ?{ ->
          {end_pos, new_col} = consume_nested(input, pos + 2, col + 2, 1, ?{, ?})
          scan_word_with_braces_loop(input, len, end_pos, new_col)

        c == ?` ->
          {end_pos, new_col} = consume_backtick(input, pos + 1, col + 1)
          scan_word_with_braces_loop(input, len, end_pos, new_col)

        true ->
          scan_word_with_braces_loop(input, len, pos + 1, col + 1)
      end
    end
  end

  defp consume_brace_expansion(input, pos, col, depth) do
    if depth == 0 or pos >= byte_size(input) do
      {pos, col}
    else
      c = char_at(input, pos)

      {new_depth, _} =
        cond do
          c == ?{ -> {depth + 1, nil}
          c == ?) -> {depth - 1, nil}
          c == ?( -> {depth + 1, nil}
          true -> {depth, nil}
        end

      consume_brace_expansion(input, pos + 1, col + 1, new_depth)
    end
  end

  defp consume_nested(input, pos, col, depth, open_char, close_char) do
    if depth == 0 or pos >= byte_size(input) do
      {pos, col}
    else
      c = char_at(input, pos)

      new_depth =
        cond do
          c == open_char -> depth + 1
          c == close_char -> depth - 1
          true -> depth
        end

      consume_nested(input, pos + 1, col + 1, new_depth, open_char, close_char)
    end
  end

  defp consume_backtick(input, pos, col) do
    c = char_at(input, pos)
    c_next = char_at(input, pos + 1)

    cond do
      c == nil -> {pos, col}
      c == ?` -> {pos + 1, col + 1}
      c == ?\\ and c_next != nil -> consume_backtick(input, pos + 2, col + 2)
      true -> consume_backtick(input, pos + 1, col + 1)
    end
  end

  defp scan_brace_expansion(input, start_pos) do
    pos = start_pos + 1
    scan_brace_expansion_loop(input, pos, byte_size(input), 1, false, false)
  end

  defp scan_brace_expansion_loop(input, pos, len, depth, has_comma, has_range) do
    if pos >= len or depth == 0 do
      if depth == 0 and (has_comma or has_range) do
        pos
      else
        nil
      end
    else
      c = char_at(input, pos)

      cond do
        c == ?{ ->
          scan_brace_expansion_loop(input, pos + 1, len, depth + 1, has_comma, has_range)

        c == ?} ->
          if depth == 1 and (has_comma or has_range) do
            pos + 1
          else
            scan_brace_expansion_loop(input, pos + 1, len, depth - 1, has_comma, has_range)
          end

        c == ?, and depth == 1 ->
          scan_brace_expansion_loop(input, pos + 1, len, depth, true, has_range)

        c == ?. and char_at(input, pos + 1) == ?. ->
          scan_brace_expansion_loop(input, pos + 2, len, depth, has_comma, true)

        c in [?\s, ?\t, ?\n, ?;, ?&, ?|] ->
          nil

        true ->
          scan_brace_expansion_loop(input, pos + 1, len, depth, has_comma, has_range)
      end
    end
  end

  defp scan_literal_brace_word(input, start_pos) do
    pos = start_pos + 1
    scan_literal_brace_loop(input, pos, byte_size(input), 1)
  end

  defp scan_literal_brace_loop(input, pos, len, depth) do
    if pos >= len or depth == 0 do
      if depth == 0, do: pos, else: nil
    else
      c = char_at(input, pos)

      cond do
        c == ?{ ->
          scan_literal_brace_loop(input, pos + 1, len, depth + 1)

        c == ?} ->
          if depth == 1 do
            pos + 1
          else
            scan_literal_brace_loop(input, pos + 1, len, depth - 1)
          end

        c in [?\s, ?\t, ?\n, ?;, ?&, ?|] ->
          nil

        true ->
          scan_literal_brace_loop(input, pos + 1, len, depth)
      end
    end
  end

  defp is_word_char_following?(input, pos) do
    case char_at(input, pos) do
      nil -> false
      c when c in [?\s, ?\t, ?\n, ?;, ?&, ?|, ?(, ?), ?<, ?>] -> false
      _ -> true
    end
  end

  defp register_heredoc_from_lookahead(lexer, strip_tabs) do
    saved_pos = lexer.pos
    saved_column = lexer.column

    lexer = skip_inline_whitespace(lexer)

    {delimiter, quoted, lexer} = read_heredoc_delimiter(lexer)

    lexer = %{lexer | pos: saved_pos, column: saved_column}

    if delimiter != "" do
      heredoc = %{delimiter: delimiter, strip_tabs: strip_tabs, quoted: quoted}
      %{lexer | pending_heredocs: lexer.pending_heredocs ++ [heredoc]}
    else
      lexer
    end
  end

  defp skip_inline_whitespace(lexer) do
    case char_at(lexer.input, lexer.pos) do
      c when c in [?\s, ?\t] ->
        skip_inline_whitespace(%{lexer | pos: lexer.pos + 1, column: lexer.column + 1})

      _ ->
        lexer
    end
  end

  defp read_heredoc_delimiter(lexer) do
    char = char_at(lexer.input, lexer.pos)

    if char in [?', ?"] do
      quote_char = char
      lexer = %{lexer | pos: lexer.pos + 1, column: lexer.column + 1}
      {delimiter, lexer} = read_until_quote(lexer, quote_char, "")
      {delimiter, true, lexer}
    else
      {delimiter, lexer} = read_unquoted_delimiter(lexer, "")
      {delimiter, false, lexer}
    end
  end

  defp read_until_quote(lexer, quote_char, acc) do
    case char_at(lexer.input, lexer.pos) do
      nil ->
        {acc, lexer}

      ^quote_char ->
        {acc, %{lexer | pos: lexer.pos + 1, column: lexer.column + 1}}

      c ->
        read_until_quote(
          %{lexer | pos: lexer.pos + 1, column: lexer.column + 1},
          quote_char,
          acc <> <<c>>
        )
    end
  end

  defp read_unquoted_delimiter(lexer, acc) do
    case char_at(lexer.input, lexer.pos) do
      nil ->
        {acc, lexer}

      c when c in [?\s, ?\t, ?\n, ?;, ?<, ?>, ?&, ?|, ?(, ?)] ->
        {acc, lexer}

      c ->
        read_unquoted_delimiter(
          %{lexer | pos: lexer.pos + 1, column: lexer.column + 1},
          acc <> <<c>>
        )
    end
  end

  defp read_heredoc_content(lexer) do
    read_all_heredocs(lexer)
  end

  defp read_all_heredocs(lexer) do
    case lexer.pending_heredocs do
      [] ->
        lexer

      [heredoc | rest] ->
        lexer = %{lexer | pending_heredocs: rest}
        {content, lexer} = read_single_heredoc(lexer, heredoc)

        token = %Token{
          type: :heredoc_content,
          value: content,
          start: lexer.pos,
          end: lexer.pos,
          line: lexer.line,
          column: lexer.column
        }

        lexer = %{lexer | tokens: [token | lexer.tokens]}
        read_all_heredocs(lexer)
    end
  end

  defp read_single_heredoc(lexer, heredoc) do
    read_heredoc_lines(lexer, heredoc, "")
  end

  defp read_heredoc_lines(lexer, heredoc, content) do
    {line_content, lexer} = read_line(lexer)

    line_to_check =
      if heredoc.strip_tabs do
        String.replace(line_content, ~r/^\t+/, "")
      else
        line_content
      end

    if line_to_check == heredoc.delimiter do
      lexer = consume_newline(lexer)
      {content, lexer}
    else
      new_content = content <> line_content

      new_content =
        if char_at(lexer.input, lexer.pos) == ?\n, do: new_content <> "\n", else: new_content

      lexer = consume_newline(lexer)
      read_heredoc_lines(lexer, heredoc, new_content)
    end
  end

  defp read_line(lexer) do
    read_line_loop(lexer, "")
  end

  defp read_line_loop(lexer, acc) do
    case char_at(lexer.input, lexer.pos) do
      nil ->
        {acc, lexer}

      ?\n ->
        {acc, lexer}

      c ->
        read_line_loop(
          %{lexer | pos: lexer.pos + 1, column: lexer.column + 1},
          acc <> <<c>>
        )
    end
  end

  defp consume_newline(lexer) do
    if char_at(lexer.input, lexer.pos) == ?\n do
      %{lexer | pos: lexer.pos + 1, line: lexer.line + 1, column: 1}
    else
      lexer
    end
  end

  defp is_special_var?(char) do
    char in [?#, ??, ?$, ?!, ?@, ?*, ?-] or (char >= ?0 and char <= ?9)
  end

  defp is_valid_name?(value) do
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, value)
  end

  defp is_assignment?(value) do
    case String.split(value, "=", parts: 2) do
      [lhs, _] when byte_size(lhs) > 0 ->
        is_valid_assignment_lhs?(lhs)

      _ ->
        false
    end
  end

  defp is_valid_assignment_lhs?(str) do
    case Regex.run(~r/^[a-zA-Z_][a-zA-Z0-9_]*/, str) do
      [match] ->
        after_name = String.slice(str, String.length(match)..-1//1)

        cond do
          after_name == "" or after_name == "+" ->
            true

          String.starts_with?(after_name, "[") ->
            check_array_subscript(after_name)

          true ->
            false
        end

      _ ->
        false
    end
  end

  defp check_array_subscript(str) do
    {depth, pos} = scan_brackets(str, 0, 0)

    if depth == 0 and pos <= String.length(str) do
      rest = String.slice(str, pos..-1//1)
      rest == "" or rest == "+"
    else
      false
    end
  end

  defp scan_brackets(str, pos, depth) do
    if pos >= String.length(str) do
      {depth, pos}
    else
      char = String.at(str, pos)

      case char do
        "[" ->
          scan_brackets(str, pos + 1, depth + 1)

        "]" when depth > 0 ->
          if depth == 1, do: {0, pos + 1}, else: scan_brackets(str, pos + 1, depth - 1)

        "]" ->
          {depth, pos}

        _ ->
          scan_brackets(str, pos + 1, depth)
      end
    end
  end

  defp char_at(binary, pos) when pos >= 0 and pos < byte_size(binary) do
    :binary.at(binary, pos)
  end

  defp char_at(_binary, _pos), do: nil
end
