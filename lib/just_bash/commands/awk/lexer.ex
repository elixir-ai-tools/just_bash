defmodule JustBash.Commands.Awk.Lexer do
  @moduledoc """
  Lexer for AWK programs.

  Tokenizes AWK source code into a stream of tokens that can be
  consumed by the parser.
  """

  # Token types
  # Literals
  @type token_type ::
          :number
          | :string
          | :regex
          # Identifiers
          | :ident
          # Keywords
          | :begin
          | :end
          | :if
          | :else
          | :while
          | :do
          | :for
          | :in
          | :break
          | :continue
          | :next
          | :exit
          | :return
          | :delete
          | :function
          | :print
          | :printf
          | :getline
          # Operators
          | :plus
          | :minus
          | :star
          | :slash
          | :percent
          | :caret
          | :eq
          | :ne
          | :lt
          | :gt
          | :le
          | :ge
          | :match
          | :not_match
          | :and
          | :or
          | :not
          | :assign
          | :plus_assign
          | :minus_assign
          | :star_assign
          | :slash_assign
          | :percent_assign
          | :caret_assign
          | :increment
          | :decrement
          | :question
          | :colon
          | :comma
          | :semicolon
          | :newline
          | :lparen
          | :rparen
          | :lbrace
          | :rbrace
          | :lbracket
          | :rbracket
          | :dollar
          | :append
          | :pipe
          | :eof

  @type token :: {token_type(), value :: term(), line :: pos_integer(), column :: pos_integer()}

  @keywords %{
    "BEGIN" => :begin,
    "END" => :end,
    "if" => :if,
    "else" => :else,
    "while" => :while,
    "do" => :do,
    "for" => :for,
    "in" => :in,
    "break" => :break,
    "continue" => :continue,
    "next" => :next,
    "exit" => :exit,
    "return" => :return,
    "delete" => :delete,
    "function" => :function,
    "print" => :print,
    "printf" => :printf,
    "getline" => :getline
  }

  # Tokens that can precede a regex literal
  @regex_preceders MapSet.new([
                     nil,
                     :newline,
                     :semicolon,
                     :lbrace,
                     :rbrace,
                     :lparen,
                     :lbracket,
                     :comma,
                     :assign,
                     :plus_assign,
                     :minus_assign,
                     :star_assign,
                     :slash_assign,
                     :percent_assign,
                     :caret_assign,
                     :and,
                     :or,
                     :not,
                     :match,
                     :not_match,
                     :question,
                     :colon,
                     :lt,
                     :gt,
                     :le,
                     :ge,
                     :eq,
                     :ne,
                     :plus,
                     :minus,
                     :star,
                     :percent,
                     :caret,
                     :print,
                     :printf,
                     :if,
                     :while,
                     :do,
                     :for,
                     :return
                   ])

  defstruct [:input, :pos, :line, :column, :last_token_type]

  @doc """
  Tokenize an AWK program string into a list of tokens.

  Returns `{:ok, tokens}` on success or `{:error, message}` on failure.
  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, String.t()}
  def tokenize(input) do
    state = %__MODULE__{
      input: input,
      pos: 0,
      line: 1,
      column: 1,
      last_token_type: nil
    }

    {:ok, do_tokenize(state, [])}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp do_tokenize(state, acc) do
    state = skip_whitespace(state)

    if state.pos >= byte_size(state.input) do
      tokens = [{:eof, "", state.line, state.column} | acc]
      Enum.reverse(tokens)
    else
      {token, state} = next_token(state)
      # Update last_token_type for regex/division disambiguation
      token_type = elem(token, 0)
      state = %{state | last_token_type: token_type}
      do_tokenize(state, [token | acc])
    end
  end

  defp skip_whitespace(state) do
    case peek(state) do
      ch when ch in [?\s, ?\t, ?\r] ->
        skip_whitespace(advance(state))

      ?\\ ->
        # Line continuation
        if peek(state, 1) == ?\n do
          state |> advance() |> advance() |> skip_whitespace()
        else
          state
        end

      ?# ->
        # Comment - skip to end of line
        skip_comment(state)

      _ ->
        state
    end
  end

  defp skip_comment(state) do
    case peek(state) do
      ?\n -> state
      nil -> state
      _ -> skip_comment(advance(state))
    end
  end

  defp next_token(state) do
    start_line = state.line
    start_column = state.column
    ch = peek(state)

    cond do
      ch == ?\n ->
        {token(:newline, "\n", start_line, start_column), advance(state)}

      ch == ?" ->
        read_string(state)

      ch == ?/ and can_be_regex?(state) ->
        read_regex(state)

      digit?(ch) or (ch == ?. and digit?(peek(state, 1))) ->
        read_number(state)

      alpha?(ch) or ch == ?_ ->
        read_identifier(state)

      true ->
        read_operator(state)
    end
  end

  defp can_be_regex?(state) do
    MapSet.member?(@regex_preceders, state.last_token_type)
  end

  defp read_string(state) do
    start_line = state.line
    start_column = state.column
    state = advance(state)
    {value, state} = read_string_content(state, [])
    {token(:string, value, start_line, start_column), state}
  end

  defp read_string_content(state, acc) do
    case peek(state) do
      ?" ->
        {IO.iodata_to_binary(Enum.reverse(acc)), advance(state)}

      ?\\ ->
        state = advance(state)
        {escaped, state} = read_escape(state)
        read_string_content(state, [escaped | acc])

      nil ->
        {IO.iodata_to_binary(Enum.reverse(acc)), state}

      ch ->
        read_string_content(advance(state), [ch | acc])
    end
  end

  defp read_escape(state) do
    ch = peek(state)

    case ch do
      ?n -> {"\n", advance(state)}
      ?t -> {"\t", advance(state)}
      ?r -> {"\r", advance(state)}
      ?f -> {"\f", advance(state)}
      ?b -> {"\b", advance(state)}
      ?v -> {"\v", advance(state)}
      ?a -> {<<7>>, advance(state)}
      ?\\ -> {"\\", advance(state)}
      ?" -> {"\"", advance(state)}
      ?/ -> {"/", advance(state)}
      ?x -> read_hex_escape(advance(state))
      ch when ch in ?0..?7 -> read_octal_escape(state)
      _ -> {<<ch>>, advance(state)}
    end
  end

  defp read_hex_escape(state) do
    {hex, state} = read_hex_digits(state, [], 2)

    if hex == "" do
      {"x", state}
    else
      {<<String.to_integer(hex, 16)>>, state}
    end
  end

  defp read_hex_digits(state, acc, 0), do: {IO.iodata_to_binary(Enum.reverse(acc)), state}

  defp read_hex_digits(state, acc, remaining) do
    ch = peek(state)

    if hex_digit?(ch) do
      read_hex_digits(advance(state), [ch | acc], remaining - 1)
    else
      {IO.iodata_to_binary(Enum.reverse(acc)), state}
    end
  end

  defp read_octal_escape(state) do
    {octal, state} = read_octal_digits(state, [], 3)
    {<<String.to_integer(octal, 8)>>, state}
  end

  defp read_octal_digits(state, acc, 0), do: {IO.iodata_to_binary(Enum.reverse(acc)), state}

  defp read_octal_digits(state, acc, remaining) do
    ch = peek(state)

    if ch in ?0..?7 do
      read_octal_digits(advance(state), [ch | acc], remaining - 1)
    else
      {IO.iodata_to_binary(Enum.reverse(acc)), state}
    end
  end

  defp read_regex(state) do
    start_line = state.line
    start_column = state.column
    state = advance(state)
    {pattern, state} = read_regex_content(state, [])
    pattern = expand_posix_classes(pattern)
    {token(:regex, pattern, start_line, start_column), state}
  end

  defp read_regex_content(state, acc) do
    case peek(state) do
      ?/ ->
        {IO.iodata_to_binary(Enum.reverse(acc)), advance(state)}

      ?\\ ->
        state = advance(state)
        ch = peek(state)

        if ch do
          read_regex_content(advance(state), [ch, ?\\ | acc])
        else
          {IO.iodata_to_binary(Enum.reverse(acc)), state}
        end

      ?\n ->
        # Unterminated regex
        {IO.iodata_to_binary(Enum.reverse(acc)), state}

      nil ->
        {IO.iodata_to_binary(Enum.reverse(acc)), state}

      ch ->
        read_regex_content(advance(state), [ch | acc])
    end
  end

  defp expand_posix_classes(pattern) do
    pattern
    |> String.replace("[[:space:]]", "[ \\t\\n\\r\\f\\v]")
    |> String.replace("[[:blank:]]", "[ \\t]")
    |> String.replace("[[:alpha:]]", "[a-zA-Z]")
    |> String.replace("[[:digit:]]", "[0-9]")
    |> String.replace("[[:alnum:]]", "[a-zA-Z0-9]")
    |> String.replace("[[:upper:]]", "[A-Z]")
    |> String.replace("[[:lower:]]", "[a-z]")
    |> String.replace("[[:xdigit:]]", "[0-9A-Fa-f]")
  end

  defp read_number(state) do
    start_line = state.line
    start_column = state.column
    {num_str, state} = read_number_str(state, [])
    value = parse_number(num_str)
    {token(:number, value, start_line, start_column), state}
  end

  defp read_number_str(state, acc) do
    ch = peek(state)

    cond do
      digit?(ch) ->
        read_number_str(advance(state), [ch | acc])

      ch == ?. and digit?(peek(state, 1)) ->
        state = advance(state)
        read_number_decimal(state, [?. | acc])

      ch in [?e, ?E] ->
        read_number_exponent(advance(state), [ch | acc])

      true ->
        {IO.iodata_to_binary(Enum.reverse(acc)), state}
    end
  end

  defp read_number_decimal(state, acc) do
    ch = peek(state)

    cond do
      digit?(ch) ->
        read_number_decimal(advance(state), [ch | acc])

      ch in [?e, ?E] ->
        read_number_exponent(advance(state), [ch | acc])

      true ->
        {IO.iodata_to_binary(Enum.reverse(acc)), state}
    end
  end

  defp read_number_exponent(state, acc) do
    ch = peek(state)

    if ch in [?+, ?-] do
      read_number_exponent_digits(advance(state), [ch | acc])
    else
      read_number_exponent_digits(state, acc)
    end
  end

  defp read_number_exponent_digits(state, acc) do
    ch = peek(state)

    if digit?(ch) do
      read_number_exponent_digits(advance(state), [ch | acc])
    else
      {IO.iodata_to_binary(Enum.reverse(acc)), state}
    end
  end

  defp parse_number(str) do
    case Float.parse(str) do
      {n, ""} -> n
      _ -> 0.0
    end
  end

  defp read_identifier(state) do
    start_line = state.line
    start_column = state.column
    {name, state} = read_identifier_str(state, [])

    token_type = Map.get(@keywords, name, :ident)
    {token(token_type, name, start_line, start_column), state}
  end

  defp read_identifier_str(state, acc) do
    ch = peek(state)

    if alphanumeric?(ch) or ch == ?_ do
      read_identifier_str(advance(state), [ch | acc])
    else
      {IO.iodata_to_binary(Enum.reverse(acc)), state}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp read_operator(state) do
    start_line = state.line
    start_column = state.column
    ch = peek(state)
    next = peek(state, 1)
    state = advance(state)

    case ch do
      ?+ ->
        cond do
          next == ?+ -> {token(:increment, "++", start_line, start_column), advance(state)}
          next == ?= -> {token(:plus_assign, "+=", start_line, start_column), advance(state)}
          true -> {token(:plus, "+", start_line, start_column), state}
        end

      ?- ->
        cond do
          next == ?- -> {token(:decrement, "--", start_line, start_column), advance(state)}
          next == ?= -> {token(:minus_assign, "-=", start_line, start_column), advance(state)}
          true -> {token(:minus, "-", start_line, start_column), state}
        end

      ?* ->
        cond do
          next == ?* ->
            # ** is power operator (alias for ^)
            {token(:caret, "**", start_line, start_column), advance(state)}

          next == ?= ->
            {token(:star_assign, "*=", start_line, start_column), advance(state)}

          true ->
            {token(:star, "*", start_line, start_column), state}
        end

      ?/ ->
        if next == ?= do
          {token(:slash_assign, "/=", start_line, start_column), advance(state)}
        else
          {token(:slash, "/", start_line, start_column), state}
        end

      ?% ->
        if next == ?= do
          {token(:percent_assign, "%=", start_line, start_column), advance(state)}
        else
          {token(:percent, "%", start_line, start_column), state}
        end

      ?^ ->
        if next == ?= do
          {token(:caret_assign, "^=", start_line, start_column), advance(state)}
        else
          {token(:caret, "^", start_line, start_column), state}
        end

      ?= ->
        if next == ?= do
          {token(:eq, "==", start_line, start_column), advance(state)}
        else
          {token(:assign, "=", start_line, start_column), state}
        end

      ?! ->
        cond do
          next == ?= -> {token(:ne, "!=", start_line, start_column), advance(state)}
          next == ?~ -> {token(:not_match, "!~", start_line, start_column), advance(state)}
          true -> {token(:not, "!", start_line, start_column), state}
        end

      ?< ->
        if next == ?= do
          {token(:le, "<=", start_line, start_column), advance(state)}
        else
          {token(:lt, "<", start_line, start_column), state}
        end

      ?> ->
        cond do
          next == ?= -> {token(:ge, ">=", start_line, start_column), advance(state)}
          next == ?> -> {token(:append, ">>", start_line, start_column), advance(state)}
          true -> {token(:gt, ">", start_line, start_column), state}
        end

      ?& ->
        if next == ?& do
          {token(:and, "&&", start_line, start_column), advance(state)}
        else
          {token(:ident, "&", start_line, start_column), state}
        end

      ?| ->
        if next == ?| do
          {token(:or, "||", start_line, start_column), advance(state)}
        else
          {token(:pipe, "|", start_line, start_column), state}
        end

      ?~ ->
        {token(:match, "~", start_line, start_column), state}

      ?? ->
        {token(:question, "?", start_line, start_column), state}

      ?: ->
        {token(:colon, ":", start_line, start_column), state}

      ?, ->
        {token(:comma, ",", start_line, start_column), state}

      ?; ->
        {token(:semicolon, ";", start_line, start_column), state}

      ?( ->
        {token(:lparen, "(", start_line, start_column), state}

      ?) ->
        {token(:rparen, ")", start_line, start_column), state}

      ?{ ->
        {token(:lbrace, "{", start_line, start_column), state}

      ?} ->
        {token(:rbrace, "}", start_line, start_column), state}

      ?[ ->
        {token(:lbracket, "[", start_line, start_column), state}

      ?] ->
        {token(:rbracket, "]", start_line, start_column), state}

      ?$ ->
        {token(:dollar, "$", start_line, start_column), state}

      _ ->
        {token(:ident, <<ch>>, start_line, start_column), state}
    end
  end

  # Helper functions

  defp token(type, value, line, column), do: {type, value, line, column}

  defp peek(%{input: input, pos: pos}) when pos >= byte_size(input), do: nil
  defp peek(%{input: input, pos: pos}), do: :binary.at(input, pos)

  defp peek(%{input: input, pos: pos}, offset) when pos + offset >= byte_size(input), do: nil
  defp peek(%{input: input, pos: pos}, offset), do: :binary.at(input, pos + offset)

  defp advance(%{input: input, pos: pos} = state) when pos >= byte_size(input), do: state

  defp advance(%{input: input, pos: pos, line: line, column: column} = state) do
    ch = :binary.at(input, pos)

    if ch == ?\n do
      %{state | pos: pos + 1, line: line + 1, column: 1, last_token_type: state.last_token_type}
    else
      %{state | pos: pos + 1, column: column + 1, last_token_type: state.last_token_type}
    end
  end

  defp digit?(nil), do: false
  defp digit?(ch), do: ch in ?0..?9

  defp alpha?(nil), do: false
  defp alpha?(ch), do: ch in ?a..?z or ch in ?A..?Z

  defp alphanumeric?(nil), do: false
  defp alphanumeric?(ch), do: digit?(ch) or alpha?(ch)

  defp hex_digit?(nil), do: false
  defp hex_digit?(ch), do: ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F
end
