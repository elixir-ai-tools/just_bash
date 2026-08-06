defmodule JustBash.Interpreter.Expansion.Brace do
  @moduledoc """
  Brace expansion for bash.

  Handles:
  - List expansion: {a,b,c}
  - Range expansion: {1..10}, {a..z}, {1..10..2}

  ## Bounds

  This is the one expansion whose output size is not bounded by anything the
  input already holds: `{1..1000000}` is twelve characters, and nesting
  multiplies. The word list is therefore produced under two bounds — the
  cardinality cap of `Limit.check_expansion_words!/2` and the wall clock — both
  applied as each word is produced rather than after the list exists.
  """

  alias JustBash.AST
  alias JustBash.Interpreter.Expansion
  alias JustBash.Limit

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
    {_count, words, assigns} = expand_into(bash, parts, {0, [], []})
    {Enum.reverse(words), Enum.reverse(assigns)}
  end

  # One accumulator is threaded through the whole cartesian walk instead of
  # each level concatenating its children's results. That keeps the walk linear
  # in the number of words rather than quadratic — `echo {1..100000}` was 18 s
  # before — and, more importantly, gives the bounds a single place that sees
  # every word at the moment it is produced.
  defp expand_into(bash, parts, {count, words, assigns} = acc) do
    case find_brace_expansion(parts) do
      nil ->
        Limit.check_deadline!(bash)
        count = count + 1
        Limit.check_expansion_words!(bash, count)
        {word, new_assigns} = Expansion.expand_word_parts(bash, parts)
        {count, [word | words], prepend_reversed(new_assigns, assigns)}

      {prefix_parts, brace_exp, suffix_parts} ->
        bash
        |> expand_brace_items(brace_exp.items)
        |> Enum.reduce(acc, fn item, item_acc ->
          new_parts = prefix_parts ++ [%AST.Literal{value: item}] ++ suffix_parts
          expand_into(bash, new_parts, item_acc)
        end)
    end
  end

  defp prepend_reversed(new, assigns), do: Enum.reduce(new, assigns, &[&1 | &2])

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
        # A range is the one item that materializes its whole list in one go,
        # so it is measured before it is built.
        Limit.check_expansion_words!(bash, range_size(start_val, end_val, step))
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

  # How long `expand_range/3` would make the list, without making it. Mirrors
  # that function's clauses exactly, including its "empty when the step runs
  # the wrong way" case; anything it would reject outright is left for it to
  # reject.
  defp range_size(start_val, end_val, step)
       when is_integer(start_val) and is_integer(end_val) do
    step = step || if start_val <= end_val, do: 1, else: -1

    if (step > 0 and start_val <= end_val) or (step < 0 and start_val >= end_val) do
      div(abs(end_val - start_val), abs(step)) + 1
    else
      0
    end
  end

  defp range_size(start_val, end_val, step)
       when is_binary(start_val) and is_binary(end_val) do
    range_size(:binary.first(start_val), :binary.first(end_val), step)
  end

  defp range_size(_start_val, _end_val, _step), do: 0

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
