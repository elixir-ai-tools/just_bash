defmodule JustBash.Parser.Lexer.Heredoc do
  @moduledoc """
  Heredoc processing for the bash lexer.

  When the lexer encounters `<<` or `<<-` followed by a delimiter word,
  this module handles:
  1. Recording the pending heredoc
  2. After a newline, consuming content until the delimiter
  3. Creating heredoc content tokens
  """

  alias JustBash.Parser.Lexer.Token

  @doc """
  Process tokens to handle heredocs.

  When we see << or <<- followed by a word, we:
  1. Record the delimiter
  2. After the next newline, consume content until delimiter
  """
  def process(tokens, input) do
    {processed, _pending} = process_loop(tokens, input, [], [])
    processed
  end

  defp process_loop([], _input, acc, _pending) do
    {Enum.reverse(acc), []}
  end

  defp process_loop([token | rest], input, acc, pending) do
    cond do
      token.type in [:dless, :dlessdash] ->
        process_heredoc_start(token, rest, input, acc, pending)

      token.type == :newline and pending != [] ->
        process_heredoc_content(token, rest, input, acc, pending)

      true ->
        process_loop(rest, input, [token | acc], pending)
    end
  end

  defp process_heredoc_start(token, rest, input, acc, pending) do
    strip_tabs = token.type == :dlessdash

    case rest do
      [delim_token | rest2] when delim_token.type in [:word, :name] ->
        delimiter = delim_token.value
        quoted = delim_token.quoted || delim_token.single_quoted
        heredoc = %{delimiter: delimiter, strip_tabs: strip_tabs, quoted: quoted}
        acc = [delim_token, token | acc]
        process_loop(rest2, input, acc, [heredoc | pending])

      _ ->
        process_loop(rest, input, [token | acc], pending)
    end
  end

  defp process_heredoc_content(token, rest, input, acc, pending) do
    acc = [token | acc]
    heredoc_start = find_newline_after(input, token.start)
    {heredoc_tokens, new_pos, _rest2} = consume_heredocs(pending, input, heredoc_start, [])
    acc = heredoc_tokens ++ acc
    rest_filtered = skip_consumed_tokens(rest, new_pos)
    process_loop(rest_filtered, input, acc, [])
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
      line_to_check = if strip_tabs, do: String.replace(line, ~r/^\t+/, ""), else: line

      if line_to_check == delimiter do
        new_pos = consume_line_and_newline(input, pos)
        {content, new_pos}
      else
        new_content = append_line_with_newline(content, line, input, end_pos)
        new_pos = if end_pos < byte_size(input), do: end_pos + 1, else: end_pos
        read_heredoc_lines(input, new_pos, delimiter, strip_tabs, new_content)
      end
    end
  end

  defp read_line_at(input, pos) do
    do_read_line_at(input, pos, pos)
  end

  defp do_read_line_at(input, start, pos) do
    cond do
      pos >= byte_size(input) ->
        {binary_part(input, start, pos - start), pos}

      :binary.at(input, pos) == ?\n ->
        {binary_part(input, start, pos - start), pos}

      true ->
        do_read_line_at(input, start, pos + 1)
    end
  end

  defp append_line_with_newline(content, line, input, end_pos) do
    has_newline = end_pos < byte_size(input) and :binary.at(input, end_pos) == ?\n

    if has_newline do
      content <> line <> "\n"
    else
      content <> line
    end
  end

  defp consume_line_and_newline(input, pos) do
    pos = skip_to_newline(input, pos)
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

  defp find_newline_after(input, pos) do
    cond do
      pos >= byte_size(input) -> pos
      :binary.at(input, pos) == ?\n -> pos + 1
      true -> find_newline_after(input, pos + 1)
    end
  end
end
