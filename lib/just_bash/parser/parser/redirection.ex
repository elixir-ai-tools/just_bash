defmodule JustBash.Parser.Redirection do
  @moduledoc """
  Parser for shell redirections.

  Handles parsing of all redirection operators:
  - Input: `<`, `<<`, `<<<`, `<&`
  - Output: `>`, `>>`, `>&`, `>|`
  - Combined: `&>`, `&>>`
  - Heredocs: `<<`, `<<-`
  """

  alias JustBash.AST
  alias JustBash.Parser.WordParts

  @redirection_op_types [
    :less,
    :great,
    :dless,
    :dgreat,
    :lessand,
    :greatand,
    :lessgreat,
    :dlessdash,
    :clobber,
    :tless,
    :and_great,
    :and_dgreat
  ]

  @doc """
  Check if the current token starts a redirection.
  """
  def redirection?(parser, helpers) do
    token = helpers.current(parser)

    token.type in @redirection_op_types or
      (token.type == :number and helpers.peek(parser, 1).type in @redirection_op_types)
  end

  @doc """
  Parse all redirections at the current position.
  """
  def parse_redirections(parser, acc, helpers) do
    if redirection?(parser, helpers) do
      {redir, parser} = parse_redirection(parser, helpers)
      parse_redirections(parser, [redir | acc], helpers)
    else
      {Enum.reverse(acc), parser}
    end
  end

  @doc """
  Parse a single redirection.
  """
  def parse_redirection(parser, helpers) do
    {fd, parser} = parse_redirection_fd(parser, helpers)
    {op_token, parser} = helpers.advance(parser)
    operator = redirection_operator(op_token.type)
    {target_token, parser} = helpers.advance(parser)

    build_redirection(parser, operator, target_token, fd, helpers)
  end

  defp parse_redirection_fd(parser, helpers) do
    if helpers.check?(parser, :number) and redirection_op?(helpers.peek(parser, 1).type) do
      {token, parser} = helpers.advance(parser)
      {String.to_integer(token.value), parser}
    else
      {nil, parser}
    end
  end

  defp redirection_op?(type), do: type in @redirection_op_types

  defp redirection_operator(:less), do: :<
  defp redirection_operator(:great), do: :>
  defp redirection_operator(:dless), do: :"<<"
  defp redirection_operator(:dgreat), do: :">>"
  defp redirection_operator(:lessand), do: :"<&"
  defp redirection_operator(:greatand), do: :">&"
  defp redirection_operator(:lessgreat), do: :<>
  defp redirection_operator(:dlessdash), do: :"<<-"
  defp redirection_operator(:clobber), do: :">|"
  defp redirection_operator(:tless), do: :<<<
  defp redirection_operator(:and_great), do: :"&>"
  defp redirection_operator(:and_dgreat), do: :"&>>"

  defp build_redirection(parser, operator, target_token, fd, _helpers)
       when operator in [:"<<", :"<<-"] do
    delimiter = target_token.value
    strip_tabs = operator == :"<<-"
    quoted = target_token.quoted || target_token.single_quoted

    heredoc = AST.here_doc(delimiter, nil, strip_tabs, quoted)
    redirection = AST.redirection(operator, heredoc, fd)
    parser = %{parser | pending_heredocs: parser.pending_heredocs ++ [delimiter]}

    {redirection, parser}
  end

  defp build_redirection(parser, operator, target_token, fd, _helpers) do
    target = AST.word(WordParts.parse(target_token.value))
    {AST.redirection(operator, target, fd), parser}
  end
end
