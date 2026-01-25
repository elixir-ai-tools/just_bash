defmodule JustBash.Parser.WordParts.Bracket do
  @moduledoc """
  Bracket matching utilities for word parts parsing.

  Provides functions to find matching brackets, braces, parentheses,
  and other paired delimiters while respecting nesting and escape sequences.
  """

  @doc """
  Find the matching closing brace `}` for an opening brace `{`.

  ## Parameters
  - `value` - The string to search in
  - `start` - Position of the opening brace

  ## Returns
  Position of the matching closing brace.

  ## Examples

      iex> find_matching_brace("${foo}", 1)
      5

      iex> find_matching_brace("${a:-${b}}", 1)
      9
  """
  @spec find_matching_brace(String.t(), non_neg_integer()) :: non_neg_integer()
  def find_matching_brace(value, start) do
    len = String.length(value)
    find_matching_bracket_loop(value, start + 1, len, 1, "{", "}")
  end

  @doc """
  Find the matching closing parenthesis `)` for an opening parenthesis `(`.

  ## Parameters
  - `value` - The string to search in
  - `start` - Position of the opening parenthesis

  ## Returns
  Position of the matching closing parenthesis.

  ## Examples

      iex> find_matching_paren("$(echo hi)", 1)
      9

      iex> find_matching_paren("$(echo $(pwd))", 1)
      13
  """
  @spec find_matching_paren(String.t(), non_neg_integer()) :: non_neg_integer()
  def find_matching_paren(value, start) do
    len = String.length(value)
    find_matching_bracket_loop(value, start + 1, len, 1, "(", ")")
  end

  @doc """
  Find the matching closing bracket `]` for an opening bracket `[`.

  ## Parameters
  - `value` - The string to search in
  - `start` - Position of the opening bracket

  ## Returns
  Position of the matching closing bracket.

  ## Examples

      iex> find_matching_bracket("arr[0]", 3)
      5

      iex> find_matching_bracket("arr[i+1]", 3)
      7
  """
  @spec find_matching_bracket(String.t(), non_neg_integer()) :: non_neg_integer()
  def find_matching_bracket(value, start) do
    len = String.length(value)
    find_matching_bracket_loop(value, start + 1, len, 1, "[", "]")
  end

  @doc """
  Find the end of a double-parenthesis arithmetic expression `))`.

  Handles nested `(( ))` arithmetic expressions and single parentheses
  for grouping within the expression.

  ## Parameters
  - `value` - The string to search in
  - `start` - Position of the first character inside `$((`

  ## Returns
  Position of the first `)` in the closing `))`.

  ## Examples

      iex> find_double_paren_end("$((1+2))", 3)
      5

      iex> find_double_paren_end("$((1+((2+3))))", 3)
      11
  """
  @spec find_double_paren_end(String.t(), non_neg_integer()) :: non_neg_integer()
  def find_double_paren_end(value, start) do
    len = String.length(value)
    find_dparen_loop(value, start, len, 1, 0)
  end

  @doc """
  Find the closing backtick for a backtick-style command substitution.

  ## Parameters
  - `value` - The string to search in
  - `start` - Position after the opening backtick

  ## Returns
  Position of the closing backtick.

  ## Examples

      iex> find_backtick_end("`echo hi`", 1)
      8
  """
  @spec find_backtick_end(String.t(), non_neg_integer()) :: non_neg_integer()
  def find_backtick_end(value, start) do
    len = String.length(value)
    find_backtick_loop(value, start, len)
  end

  @doc """
  Find the end of a glob bracket pattern `[...]`.

  ## Parameters
  - `value` - The string to search in
  - `start` - Position of the opening bracket

  ## Returns
  `{:ok, position}` of the closing bracket, or `:error` if not found.

  ## Examples

      iex> find_glob_bracket_end("[abc]", 0)
      {:ok, 4}

      iex> find_glob_bracket_end("[a-z]", 0)
      {:ok, 4}
  """
  @spec find_glob_bracket_end(String.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def find_glob_bracket_end(value, start) do
    len = String.length(value)
    find_glob_bracket_loop(value, start + 1, len)
  end

  # Private implementation functions

  defp find_matching_bracket_loop(_value, i, len, depth, _open, _close)
       when depth == 0 or i >= len,
       do: i - 1

  defp find_matching_bracket_loop(value, i, len, depth, open, close) do
    char = String.at(value, i)

    cond do
      char == open ->
        find_matching_bracket_loop(value, i + 1, len, depth + 1, open, close)

      char == close ->
        find_matching_bracket_loop(value, i + 1, len, depth - 1, open, close)

      char == "\\" and i + 1 < len ->
        # Skip escaped character
        find_matching_bracket_loop(value, i + 2, len, depth, open, close)

      char == "'" ->
        # Skip single-quoted string entirely
        end_quote = find_single_quote_end(value, i + 1, len)
        find_matching_bracket_loop(value, end_quote + 1, len, depth, open, close)

      char == "\"" ->
        # Skip double-quoted string entirely
        end_quote = find_double_quote_end(value, i + 1, len)
        find_matching_bracket_loop(value, end_quote + 1, len, depth, open, close)

      true ->
        find_matching_bracket_loop(value, i + 1, len, depth, open, close)
    end
  end

  # Find end of single-quoted string (no escapes in single quotes)
  defp find_single_quote_end(_value, i, len) when i >= len, do: len

  defp find_single_quote_end(value, i, len) do
    if String.at(value, i) == "'" do
      i
    else
      find_single_quote_end(value, i + 1, len)
    end
  end

  # Find end of double-quoted string (handles escapes)
  defp find_double_quote_end(_value, i, len) when i >= len, do: len

  defp find_double_quote_end(value, i, len) do
    char = String.at(value, i)

    cond do
      char == "\"" ->
        i

      char == "\\" and i + 1 < len ->
        # Skip escaped character
        find_double_quote_end(value, i + 2, len)

      true ->
        find_double_quote_end(value, i + 1, len)
    end
  end

  # When outer_depth reaches 0, i points to the position after ))
  # Return i - 2 to point to the first ) of ))
  defp find_dparen_loop(_value, i, _len, 0, _paren_depth), do: i - 2

  defp find_dparen_loop(_value, i, len, _outer_depth, _paren_depth) when i >= len - 1, do: i - 1

  defp find_dparen_loop(value, i, len, outer_depth, paren_depth) do
    char = String.at(value, i)
    next = String.at(value, i + 1)
    {new_i, new_outer, new_paren} = handle_dparen_char(char, next, i, outer_depth, paren_depth)
    find_dparen_loop(value, new_i, len, new_outer, new_paren)
  end

  defp handle_dparen_char("(", "(", i, outer_depth, paren_depth) do
    {i + 2, outer_depth + 1, paren_depth}
  end

  defp handle_dparen_char(")", ")", i, outer_depth, 0) do
    {i + 2, outer_depth - 1, 0}
  end

  defp handle_dparen_char("(", _next, i, outer_depth, paren_depth) do
    {i + 1, outer_depth, paren_depth + 1}
  end

  defp handle_dparen_char(")", _next, i, outer_depth, paren_depth) when paren_depth > 0 do
    {i + 1, outer_depth, paren_depth - 1}
  end

  defp handle_dparen_char(_char, _next, i, outer_depth, paren_depth) do
    {i + 1, outer_depth, paren_depth}
  end

  defp find_backtick_loop(_value, i, len) when i >= len, do: i

  defp find_backtick_loop(value, i, len) do
    char = String.at(value, i)

    cond do
      char == "`" -> i
      char == "\\" and i + 1 < len -> find_backtick_loop(value, i + 2, len)
      true -> find_backtick_loop(value, i + 1, len)
    end
  end

  defp find_glob_bracket_loop(_value, i, len) when i >= len, do: :error

  defp find_glob_bracket_loop(value, i, len) do
    char = String.at(value, i)

    cond do
      char == "]" -> {:ok, i}
      char == "\\" and i + 1 < len -> find_glob_bracket_loop(value, i + 2, len)
      true -> find_glob_bracket_loop(value, i + 1, len)
    end
  end
end
