defmodule JustBash.Parser.Lexer.BraceExpansion do
  @moduledoc """
  Brace expansion token merging for the bash lexer.

  Handles sequences like `{a,b,c}` or `{1..10}` by merging tokens:
  - `[word?, lbrace, content, rbrace, word?]`

  Into a single word token when the content contains `,` or `..`.
  """

  alias JustBash.Parser.Lexer.Token

  @doc """
  Process tokens to merge brace expansions into single word tokens.
  """
  def process(tokens) do
    process_loop(tokens, [])
  end

  defp process_loop([], acc), do: Enum.reverse(acc)

  defp process_loop([%Token{type: :lbrace} = lbrace | rest], acc) do
    case try_merge_brace_expansion(rest, lbrace, acc) do
      {:merged, new_token, remaining, new_acc} ->
        process_loop(remaining, [new_token | new_acc])

      :not_brace_expansion ->
        process_loop(rest, [lbrace | acc])
    end
  end

  defp process_loop([token | rest], acc) do
    process_loop(rest, [token | acc])
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

  @terminating_types [:newline, :semicolon, :pipe, :amp, :and_and, :or_or, :eof]

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
       when type in @terminating_types do
    :error
  end

  defp collect_brace_content([token | rest], depth, acc) do
    collect_brace_content(rest, depth, [token | acc])
  end

  defp brace_expansion_content?(content) do
    String.contains?(content, ",") or String.contains?(content, "..")
  end
end
