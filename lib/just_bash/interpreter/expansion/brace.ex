defmodule JustBash.Interpreter.Expansion.Brace do
  @moduledoc """
  Brace expansion for bash.

  Handles:
  - List expansion: {a,b,c}
  - Range expansion: {1..10}, {a..z}, {1..10..2}
  """

  alias JustBash.AST
  alias JustBash.Interpreter.Expansion

  @typedoc "Pending variable assignments from expansions"
  @type pending_assignments :: Expansion.pending_assignments()

  @doc """
  Check if word parts contain a brace expansion.
  """
  @spec has_brace_expansion?([AST.word_part()]) :: boolean()
  def has_brace_expansion?(parts) do
    Enum.any?(parts, fn
      %AST.BraceExpansion{} -> true
      _ -> false
    end)
  end

  @doc """
  Expand word parts that may contain brace expansions.
  Returns {list_of_expanded_strings, pending_assignments}.
  """
  @spec expand_with_brace(JustBash.t(), [AST.word_part()]) ::
          {[String.t()], pending_assignments()}
  def expand_with_brace(bash, parts) do
    case find_brace_expansion(parts) do
      nil ->
        {expanded, assignments} = Expansion.expand_word_parts(bash, parts)
        {[expanded], assignments}

      {prefix_parts, brace_exp, suffix_parts} ->
        expanded_items = expand_brace_items(bash, brace_exp.items)

        {words, all_assigns} =
          Enum.reduce(expanded_items, {[], []}, fn item, {words_acc, assigns_acc} ->
            new_parts = prefix_parts ++ [%AST.Literal{value: item}] ++ suffix_parts
            {new_words, new_assigns} = expand_with_brace(bash, new_parts)
            {words_acc ++ new_words, assigns_acc ++ new_assigns}
          end)

        {words, all_assigns}
    end
  end

  @doc """
  Expand brace expansion items (words and ranges).
  """
  @spec expand_brace_items(JustBash.t(), [AST.brace_item()]) :: [String.t()]
  def expand_brace_items(bash, items) do
    Enum.flat_map(items, fn
      {:word, word} ->
        {words, _assigns} = expand_with_brace(bash, word.parts)
        words

      {:range, start_val, end_val, step} ->
        expand_range(start_val, end_val, step)
    end)
  end

  @doc """
  Expand a range (numeric or character).
  """
  @spec expand_range(integer() | String.t(), integer() | String.t(), integer() | nil) :: [
          String.t()
        ]
  def expand_range(start_val, end_val, step)
      when is_integer(start_val) and is_integer(end_val) do
    step = step || if start_val <= end_val, do: 1, else: -1

    if (step > 0 and start_val <= end_val) or (step < 0 and start_val >= end_val) do
      Range.new(start_val, end_val, step)
      |> Enum.map(&Integer.to_string/1)
    else
      []
    end
  end

  def expand_range(start_val, end_val, step)
      when is_binary(start_val) and is_binary(end_val) do
    start_char = :binary.first(start_val)
    end_char = :binary.first(end_val)
    step = step || if start_char <= end_char, do: 1, else: -1

    if (step > 0 and start_char <= end_char) or (step < 0 and start_char >= end_char) do
      Range.new(start_char, end_char, step)
      |> Enum.map(&<<&1>>)
    else
      []
    end
  end

  # Private helpers

  defp find_brace_expansion(parts) do
    find_brace_expansion_loop(parts, [])
  end

  defp find_brace_expansion_loop([], _prefix), do: nil

  defp find_brace_expansion_loop([%AST.BraceExpansion{} = brace | rest], prefix) do
    {Enum.reverse(prefix), brace, rest}
  end

  defp find_brace_expansion_loop([part | rest], prefix) do
    find_brace_expansion_loop(rest, [part | prefix])
  end
end
