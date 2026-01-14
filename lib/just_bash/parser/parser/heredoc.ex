defmodule JustBash.Parser.Heredoc do
  @moduledoc """
  Heredoc content handling for the parser.

  Handles filling heredoc content after the initial parse,
  associating heredoc content tokens with their corresponding
  redirection AST nodes.
  """

  alias JustBash.AST
  alias JustBash.Parser.WordParts

  @doc """
  Fill heredoc contents into pipelines after parsing a statement.
  """
  def fill_heredoc_contents(pipelines, parser, helpers) do
    parser = skip_to_heredoc_content(parser, helpers)
    {contents, parser} = consume_all_heredoc_contents(parser, [], helpers)
    {filled_pipelines, _remaining} = fill_heredocs_in_pipelines(pipelines, contents)
    parser = %{parser | pending_heredocs: []}
    {filled_pipelines, parser}
  end

  defp skip_to_heredoc_content(parser, helpers) do
    if helpers.check?(parser, :newline) do
      {_token, parser} = helpers.advance(parser)
      skip_to_heredoc_content(parser, helpers)
    else
      parser
    end
  end

  defp consume_all_heredoc_contents(parser, acc, helpers) do
    if helpers.check?(parser, :heredoc_content) do
      {token, parser} = helpers.advance(parser)
      consume_all_heredoc_contents(parser, acc ++ [token.value], helpers)
    else
      {acc, parser}
    end
  end

  defp fill_heredocs_in_pipelines(pipelines, contents) do
    Enum.map_reduce(pipelines, contents, fn pipeline, contents ->
      {filled_commands, remaining} =
        Enum.map_reduce(pipeline.commands, contents, fn cmd, contents ->
          fill_heredocs_in_command(cmd, contents)
        end)

      {%{pipeline | commands: filled_commands}, remaining}
    end)
  end

  defp fill_heredocs_in_command(%AST.SimpleCommand{redirections: redirs} = cmd, contents) do
    {filled_redirs, remaining} = fill_heredocs_in_redirections(redirs, contents)
    {%{cmd | redirections: filled_redirs}, remaining}
  end

  defp fill_heredocs_in_command(cmd, contents) do
    {cmd, contents}
  end

  defp fill_heredocs_in_redirections(redirections, contents) do
    Enum.map_reduce(redirections, contents, &fill_heredoc_in_redirection/2)
  end

  defp fill_heredoc_in_redirection(redir, contents) do
    case redir.target do
      %AST.HereDoc{content: nil} = heredoc ->
        fill_empty_heredoc(redir, heredoc, contents)

      _ ->
        {redir, contents}
    end
  end

  defp fill_empty_heredoc(redir, heredoc, [content | rest]) do
    word_content =
      if heredoc.quoted do
        # Quoted heredoc (<<'EOF' or <<"EOF"): no expansion
        AST.word([AST.literal(content)])
      else
        # Unquoted heredoc: expand variables, etc.
        AST.word(WordParts.parse(content))
      end

    filled_heredoc = %{heredoc | content: word_content}
    {%{redir | target: filled_heredoc}, rest}
  end

  defp fill_empty_heredoc(redir, _heredoc, []), do: {redir, []}
end
