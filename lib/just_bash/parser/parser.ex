defmodule JustBash.Parser do
  @moduledoc """
  Recursive Descent Parser for Bash Scripts

  This parser consumes tokens from the lexer and produces an AST.
  It follows the bash grammar structure for correctness.

  Grammar (simplified):
    script       ::= statement*
    statement    ::= pipeline ((&&|'||') pipeline)*  [&]
    pipeline     ::= [!] command (| command)*
    command      ::= simple_command | compound_command | function_def
    simple_cmd   ::= (assignment)* [word] (word)* (redirection)*
    compound_cmd ::= if | for | while | until | case | subshell | group | (( | [[
  """

  alias JustBash.AST
  alias JustBash.Parser.Lexer
  alias JustBash.Parser.Lexer.Token
  alias JustBash.Parser.WordParts

  @max_parse_iterations 100_000

  defmodule ParseError do
    @moduledoc "Parse error with position information"
    defexception [:message, :line, :column, :token]

    @type t :: %__MODULE__{
            message: String.t(),
            line: non_neg_integer(),
            column: non_neg_integer(),
            token: any()
          }

    @impl true
    def message(%{message: msg, line: line, column: col}) do
      "Parse error at line #{line}, column #{col}: #{msg}"
    end
  end

  defstruct tokens: [],
            pos: 0,
            pending_heredocs: [],
            parse_iterations: 0

  @type t :: %__MODULE__{
          tokens: [Token.t()],
          pos: non_neg_integer(),
          pending_heredocs: list(),
          parse_iterations: non_neg_integer()
        }

  @doc """
  Parse a bash script string into an AST.
  """
  @spec parse(String.t()) :: {:ok, AST.Script.t()} | {:error, ParseError.t()}
  def parse(input) when is_binary(input) do
    tokens = Lexer.tokenize(input)
    parser = %__MODULE__{tokens: tokens, pos: 0}

    try do
      {ast, _parser} = parse_script(parser)
      {:ok, ast}
    rescue
      e in ParseError -> {:error, e}
    end
  end

  @doc """
  Parse a bash script string into an AST, raising on error.
  """
  @spec parse!(String.t()) :: AST.Script.t()
  def parse!(input) when is_binary(input) do
    case parse(input) do
      {:ok, ast} -> ast
      {:error, error} -> raise error
    end
  end

  defp current(parser) do
    Enum.at(parser.tokens, parser.pos) || List.last(parser.tokens)
  end

  defp peek(parser, offset) do
    Enum.at(parser.tokens, parser.pos + offset) || List.last(parser.tokens)
  end

  defp advance(parser) do
    token = current(parser)

    new_pos =
      if parser.pos < length(parser.tokens) - 1 do
        parser.pos + 1
      else
        parser.pos
      end

    {token, %{parser | pos: new_pos}}
  end

  defp check?(parser, types) when is_list(types) do
    current(parser).type in types
  end

  defp check?(parser, type) when is_atom(type) do
    current(parser).type == type
  end

  defp expect(parser, type_or_types, message \\ nil)

  defp expect(parser, types, message) when is_list(types) do
    if check?(parser, types) do
      advance(parser)
    else
      token = current(parser)
      msg = message || "Expected one of #{inspect(types)}, got #{token.type}"
      raise ParseError, message: msg, line: token.line, column: token.column, token: token
    end
  end

  defp expect(parser, type, message) when is_atom(type) do
    if check?(parser, type) do
      advance(parser)
    else
      token = current(parser)
      msg = message || "Expected #{type}, got #{token.type}"
      raise ParseError, message: msg, line: token.line, column: token.column, token: token
    end
  end

  defp error(parser, message) do
    token = current(parser)
    raise ParseError, message: message, line: token.line, column: token.column, token: token
  end

  defp check_iteration_limit(parser) do
    if parser.parse_iterations > @max_parse_iterations do
      error(parser, "Maximum parse iterations exceeded (possible infinite loop)")
    end

    %{parser | parse_iterations: parser.parse_iterations + 1}
  end

  defp skip_newlines(parser) do
    if check?(parser, [:newline, :comment]) do
      if check?(parser, :newline) do
        {_token, parser} = advance(parser)
        parser = process_heredocs(parser)
        skip_newlines(parser)
      else
        {_token, parser} = advance(parser)
        skip_newlines(parser)
      end
    else
      parser
    end
  end

  defp skip_separators(parser, include_case_terminators \\ true) do
    cond do
      check?(parser, :newline) ->
        {_token, parser} = advance(parser)
        parser = process_heredocs(parser)
        skip_separators(parser, include_case_terminators)

      check?(parser, [:semicolon, :comment]) ->
        {_token, parser} = advance(parser)
        skip_separators(parser, include_case_terminators)

      include_case_terminators and check?(parser, [:dsemi, :semi_and, :semi_semi_and]) ->
        {_token, parser} = advance(parser)
        skip_separators(parser, include_case_terminators)

      true ->
        parser
    end
  end

  defp process_heredocs(parser) do
    parser
  end

  defp statement_end?(parser) do
    check?(parser, [
      :eof,
      :newline,
      :semicolon,
      :amp,
      :and_and,
      :or_or,
      :rparen,
      :rbrace,
      :dsemi,
      :semi_and,
      :semi_semi_and
    ])
  end

  defp command_start?(parser) do
    check?(parser, [
      :word,
      :name,
      :number,
      :assignment_word,
      :if,
      :for,
      :while,
      :until,
      :case,
      :lparen,
      :lbrace,
      :dparen_start,
      :dbrack_start,
      :function,
      :bang,
      :in,
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
    ])
  end

  defp parse_script(parser) do
    parser = skip_newlines(parser)
    parse_script_loop(parser, [], 0)
  end

  defp parse_script_loop(parser, statements, iterations) do
    if iterations > 10_000 do
      error(parser, "Parser stuck: too many iterations")
    end

    if check?(parser, :eof) do
      {AST.script(Enum.reverse(statements)), parser}
    else
      parser = check_unexpected_token(parser)
      pos_before = parser.pos

      {stmt, parser} = parse_statement(parser)
      parser = skip_separators(parser, false)

      if check?(parser, [:dsemi, :semi_and, :semi_semi_and]) do
        token = current(parser)
        error(parser, "syntax error near unexpected token `#{token.value}'")
      end

      parser =
        if parser.pos == pos_before and not check?(parser, :eof) do
          {_token, parser} = advance(parser)
          parser
        else
          parser
        end

      new_statements =
        if stmt do
          [stmt | statements]
        else
          statements
        end

      parse_script_loop(parser, new_statements, iterations + 1)
    end
  end

  defp check_unexpected_token(parser) do
    token = current(parser)

    if token.type in [:do, :done, :then, :else, :elif, :fi, :esac] do
      error(parser, "syntax error near unexpected token `#{token.value}'")
    end

    if token.type in [:rbrace, :rparen] do
      error(parser, "syntax error near unexpected token `#{token.value}'")
    end

    if token.type in [:dsemi, :semi_and, :semi_semi_and] do
      error(parser, "syntax error near unexpected token `#{token.value}'")
    end

    if token.type == :semicolon do
      error(parser, "syntax error near unexpected token `#{token.value}'")
    end

    parser
  end

  defp parse_statement(parser) do
    parser = skip_newlines(parser)

    if command_start?(parser) do
      pending_before = length(parser.pending_heredocs)
      {pipelines, operators, background, parser} = parse_statement_inner(parser)
      pending_after = length(parser.pending_heredocs)

      {pipelines, parser} =
        if pending_after > pending_before do
          fill_heredoc_contents(pipelines, parser)
        else
          {pipelines, parser}
        end

      {AST.statement(pipelines, operators, background), parser}
    else
      {nil, parser}
    end
  end

  defp fill_heredoc_contents(pipelines, parser) do
    parser = skip_to_heredoc_content(parser)
    {contents, parser} = consume_all_heredoc_contents(parser, [])
    {filled_pipelines, _remaining} = fill_heredocs_in_pipelines(pipelines, contents)
    parser = %{parser | pending_heredocs: []}
    {filled_pipelines, parser}
  end

  defp skip_to_heredoc_content(parser) do
    if check?(parser, :newline) do
      {_token, parser} = advance(parser)
      skip_to_heredoc_content(parser)
    else
      parser
    end
  end

  defp consume_all_heredoc_contents(parser, acc) do
    if check?(parser, :heredoc_content) do
      {token, parser} = advance(parser)
      consume_all_heredoc_contents(parser, acc ++ [token.value])
    else
      {acc, parser}
    end
  end

  defp fill_heredocs_in_pipelines(pipelines, contents) do
    {filled, remaining} =
      Enum.map_reduce(pipelines, contents, fn pipeline, contents ->
        {filled_commands, remaining} =
          Enum.map_reduce(pipeline.commands, contents, fn cmd, contents ->
            fill_heredocs_in_command(cmd, contents)
          end)

        {%{pipeline | commands: filled_commands}, remaining}
      end)

    {filled, remaining}
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

  defp parse_statement_inner(parser) do
    {first_pipeline, parser} = parse_pipeline(parser)
    parse_statement_chain(parser, [first_pipeline], [])
  end

  defp parse_statement_chain(parser, pipelines, operators) do
    if check?(parser, [:and_and, :or_or]) do
      {op_token, parser} = advance(parser)
      op = if op_token.type == :and_and, do: :and, else: :or
      parser = skip_newlines(parser)
      {next_pipeline, parser} = parse_pipeline(parser)
      parse_statement_chain(parser, [next_pipeline | pipelines], [op | operators])
    else
      {background, parser} =
        if check?(parser, :amp) do
          {_token, parser} = advance(parser)
          {true, parser}
        else
          {false, parser}
        end

      {Enum.reverse(pipelines), Enum.reverse(operators), background, parser}
    end
  end

  defp parse_pipeline(parser) do
    {negation_count, parser} = count_negations(parser, 0)
    negated = rem(negation_count, 2) == 1

    {first_cmd, parser} = parse_command(parser)
    {commands, parser} = parse_pipeline_chain(parser, [first_cmd])

    {AST.pipeline(commands, negated), parser}
  end

  defp count_negations(parser, count) do
    if check?(parser, :bang) do
      {_token, parser} = advance(parser)
      count_negations(parser, count + 1)
    else
      {count, parser}
    end
  end

  defp parse_pipeline_chain(parser, commands) do
    if check?(parser, [:pipe, :pipe_amp]) do
      {pipe_token, parser} = advance(parser)
      parser = skip_newlines(parser)
      {next_cmd, parser} = parse_command(parser)

      next_cmd =
        if pipe_token.type == :pipe_amp and match?(%AST.SimpleCommand{}, next_cmd) do
          redir = AST.redirection(:">&", AST.word([AST.literal("1")]), 2)
          %{next_cmd | redirections: [redir | next_cmd.redirections]}
        else
          next_cmd
        end

      parse_pipeline_chain(parser, [next_cmd | commands])
    else
      {Enum.reverse(commands), parser}
    end
  end

  @command_type_map %{
    if: :if,
    for: :for,
    while: :while,
    until: :until,
    case: :case,
    lparen: :subshell,
    lbrace: :group,
    dparen_start: :arithmetic,
    dbrack_start: :conditional,
    function: :function
  }

  defp parse_command(parser) do
    dispatch_command(command_type(parser), parser)
  end

  defp dispatch_command(:if, parser), do: parse_if(parser)
  defp dispatch_command(:for, parser), do: parse_for(parser)
  defp dispatch_command(:while, parser), do: parse_while(parser)
  defp dispatch_command(:until, parser), do: parse_until(parser)
  defp dispatch_command(:case, parser), do: parse_case(parser)
  defp dispatch_command(:subshell, parser), do: parse_subshell(parser)
  defp dispatch_command(:group, parser), do: parse_group(parser)
  defp dispatch_command(:arithmetic, parser), do: parse_arithmetic_command(parser)
  defp dispatch_command(:conditional, parser), do: parse_conditional_command(parser)
  defp dispatch_command(:function, parser), do: parse_function_def(parser)
  defp dispatch_command(:simple, parser), do: parse_simple_command(parser)

  defp command_type(parser) do
    current_type = current(parser).type

    case Map.get(@command_type_map, current_type) do
      nil -> command_type_fallback(parser)
      type -> type
    end
  end

  defp command_type_fallback(parser) do
    if function_def?(parser), do: :function, else: :simple
  end

  defp function_def?(parser) do
    check?(parser, [:name, :word]) and
      peek(parser, 1).type == :lparen and
      peek(parser, 2).type == :rparen
  end

  defp parse_simple_command(parser) do
    parser = check_iteration_limit(parser)
    {assignments, parser} = parse_assignments(parser, [])
    {name, args, parser} = parse_command_words(parser)
    {redirections, parser} = parse_redirections(parser, [])

    line =
      cond do
        name -> current(parser).line
        assignments != [] -> current(parser).line
        true -> nil
      end

    {AST.simple_command(name, args, assignments, redirections, line), parser}
  end

  defp parse_assignments(parser, acc) do
    if check?(parser, :assignment_word) do
      {token, parser} = advance(parser)

      # Check if this is an array assignment: arr=(...)
      if check?(parser, :lparen) do
        {assignment, parser} = parse_array_assignment(token.value, parser)
        parse_assignments(parser, [assignment | acc])
      else
        assignment = parse_assignment_word(token.value)
        parse_assignments(parser, [assignment | acc])
      end
    else
      {Enum.reverse(acc), parser}
    end
  end

  defp parse_array_assignment(assign_token_value, parser) do
    # assign_token_value is "arr=" - extract the name
    name = String.trim_trailing(assign_token_value, "=")

    # Consume the lparen
    {_lparen, parser} = advance(parser)

    # Parse elements until rparen
    {elements, parser} = parse_array_elements(parser, [])

    # Expect rparen
    {_rparen, parser} = expect(parser, :rparen, "Expected ')' to close array")

    assignment = AST.assignment(name, nil, false, elements)
    {assignment, parser}
  end

  defp parse_array_elements(parser, acc) do
    cond do
      check?(parser, :rparen) ->
        {Enum.reverse(acc), parser}

      word?(parser) ->
        {token, parser} = advance(parser)
        word = parse_word_from_token(token)
        parse_array_elements(parser, [word | acc])

      true ->
        {Enum.reverse(acc), parser}
    end
  end

  defp parse_assignment_word(value) do
    case String.split(value, "=", parts: 2) do
      [lhs, rhs] ->
        {name, append} =
          if String.ends_with?(lhs, "+") do
            {String.slice(lhs, 0..-2//1), true}
          else
            {lhs, false}
          end

        word_value =
          if rhs == "" do
            nil
          else
            AST.word(WordParts.parse(rhs, assignment: true))
          end

        AST.assignment(name, word_value, append)

      _ ->
        AST.assignment(value, nil)
    end
  end

  defp parse_command_words(parser) do
    if word?(parser) do
      {name_token, parser} = advance(parser)
      name = parse_word_from_token(name_token)
      {args, parser} = parse_args(parser, [])
      {name, args, parser}
    else
      {nil, [], parser}
    end
  end

  defp parse_args(parser, acc) do
    # Don't consume a number if it's a redirection fd (e.g., 2>/dev/null)
    if word?(parser) and not statement_end?(parser) and not redirection?(parser) do
      {token, parser} = advance(parser)
      word = parse_word_from_token(token)
      parse_args(parser, [word | acc])
    else
      {Enum.reverse(acc), parser}
    end
  end

  defp word?(parser) do
    check?(parser, [
      :word,
      :name,
      :number,
      :assignment_word,
      :if,
      :for,
      :while,
      :until,
      :case,
      :function,
      :else,
      :elif,
      :fi,
      :then,
      :do,
      :done,
      :esac,
      :in,
      :select,
      :time,
      :coproc,
      :bang
    ])
  end

  defp parse_word_from_token(token) do
    parts =
      WordParts.parse(
        token.value,
        quoted: token.quoted,
        single_quoted: token.single_quoted
      )

    AST.word(parts)
  end

  defp parse_redirections(parser, acc) do
    if redirection?(parser) do
      {redir, parser} = parse_redirection(parser)
      parse_redirections(parser, [redir | acc])
    else
      {Enum.reverse(acc), parser}
    end
  end

  defp redirection?(parser) do
    token = current(parser)

    token.type in [
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
    ] or
      (token.type == :number and
         peek(parser, 1).type in [
           :less,
           :great,
           :dless,
           :dgreat,
           :lessand,
           :greatand,
           :lessgreat,
           :dlessdash,
           :clobber,
           :and_great,
           :and_dgreat
         ])
  end

  defp parse_redirection(parser) do
    {fd, parser} = parse_redirection_fd(parser)
    {op_token, parser} = advance(parser)
    operator = redirection_operator(op_token.type)
    {target_token, parser} = advance(parser)

    build_redirection(parser, operator, target_token, fd)
  end

  defp parse_redirection_fd(parser) do
    if check?(parser, :number) and redirection_op?(peek(parser, 1).type) do
      {token, parser} = advance(parser)
      {String.to_integer(token.value), parser}
    else
      {nil, parser}
    end
  end

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
    :and_great,
    :and_dgreat
  ]

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

  defp build_redirection(parser, operator, target_token, fd)
       when operator in [:"<<", :"<<-"] do
    delimiter = target_token.value
    strip_tabs = operator == :"<<-"
    # Check token metadata for quoted status (lexer strips quotes but preserves metadata)
    quoted = target_token.quoted || target_token.single_quoted

    heredoc = AST.here_doc(delimiter, nil, strip_tabs, quoted)
    redirection = AST.redirection(operator, heredoc, fd)
    parser = %{parser | pending_heredocs: parser.pending_heredocs ++ [delimiter]}

    {redirection, parser}
  end

  defp build_redirection(parser, operator, target_token, fd) do
    target = AST.word(WordParts.parse(target_token.value))
    {AST.redirection(operator, target, fd), parser}
  end

  defp parse_if(parser) do
    {_token, parser} = expect(parser, :if)
    parser = skip_newlines(parser)

    {condition, parser} = parse_compound_list(parser)
    {_token, parser} = expect(parser, :then, "Expected 'then'")
    parser = skip_newlines(parser)

    {body, parser} = parse_compound_list(parser)
    first_clause = AST.if_clause(condition, body)

    {clauses, else_body, parser} = parse_elif_else(parser, [first_clause])

    {_token, parser} = expect(parser, :fi, "Expected 'fi'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.if_node(clauses, else_body, redirections), parser}
  end

  defp parse_elif_else(parser, clauses) do
    cond do
      check?(parser, :elif) ->
        {_token, parser} = advance(parser)
        parser = skip_newlines(parser)
        {condition, parser} = parse_compound_list(parser)
        {_token, parser} = expect(parser, :then, "Expected 'then'")
        parser = skip_newlines(parser)
        {body, parser} = parse_compound_list(parser)
        new_clause = AST.if_clause(condition, body)
        parse_elif_else(parser, [new_clause | clauses])

      check?(parser, :else) ->
        {_token, parser} = advance(parser)
        parser = skip_newlines(parser)
        {else_body, parser} = parse_compound_list(parser)
        {Enum.reverse(clauses), else_body, parser}

      true ->
        {Enum.reverse(clauses), nil, parser}
    end
  end

  defp parse_for(parser) do
    {_token, parser} = expect(parser, :for)
    parser = skip_newlines(parser)

    {var_token, parser} = expect(parser, [:name, :word], "Expected variable name")
    variable = var_token.value

    parser = skip_newlines(parser)

    {words, parser} =
      if check?(parser, :in) do
        {_token, parser} = advance(parser)
        {word_list, parser} = parse_word_list(parser)
        {word_list, parser}
      else
        {nil, parser}
      end

    parser = skip_separators(parser)
    {_token, parser} = expect(parser, :do, "Expected 'do'")
    parser = skip_newlines(parser)

    {body, parser} = parse_compound_list(parser)

    {_token, parser} = expect(parser, :done, "Expected 'done'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.for_node(variable, words, body, redirections), parser}
  end

  defp parse_word_list(parser) do
    parse_word_list_loop(parser, [])
  end

  defp parse_word_list_loop(parser, acc) do
    if word?(parser) and not check?(parser, [:semicolon, :newline, :do]) do
      {token, parser} = advance(parser)
      word = parse_word_from_token(token)
      parse_word_list_loop(parser, [word | acc])
    else
      {Enum.reverse(acc), parser}
    end
  end

  defp parse_while(parser) do
    {_token, parser} = expect(parser, :while)
    parser = skip_newlines(parser)

    {condition, parser} = parse_compound_list(parser)
    {_token, parser} = expect(parser, :do, "Expected 'do'")
    parser = skip_newlines(parser)

    {body, parser} = parse_compound_list(parser)

    {_token, parser} = expect(parser, :done, "Expected 'done'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.while_node(condition, body, redirections), parser}
  end

  defp parse_until(parser) do
    {_token, parser} = expect(parser, :until)
    parser = skip_newlines(parser)

    {condition, parser} = parse_compound_list(parser)
    {_token, parser} = expect(parser, :do, "Expected 'do'")
    parser = skip_newlines(parser)

    {body, parser} = parse_compound_list(parser)

    {_token, parser} = expect(parser, :done, "Expected 'done'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.until_node(condition, body, redirections), parser}
  end

  defp parse_case(parser) do
    {_token, parser} = expect(parser, :case)
    parser = skip_newlines(parser)

    {word_token, parser} = advance(parser)
    word = parse_word_from_token(word_token)

    parser = skip_newlines(parser)
    {_token, parser} = expect(parser, :in, "Expected 'in'")
    parser = skip_newlines(parser)

    {items, parser} = parse_case_items(parser, [])

    {_token, parser} = expect(parser, :esac, "Expected 'esac'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.case_node(word, items, redirections), parser}
  end

  defp parse_case_items(parser, acc) do
    parser = skip_newlines(parser)

    if check?(parser, :esac) do
      {Enum.reverse(acc), parser}
    else
      {item, parser} = parse_case_item(parser)
      parse_case_items(parser, [item | acc])
    end
  end

  defp parse_case_item(parser) do
    parser =
      if check?(parser, :lparen) do
        {_token, parser} = advance(parser)
        parser
      else
        parser
      end

    {patterns, parser} = parse_case_patterns(parser)
    {_token, parser} = expect(parser, :rparen, "Expected ')' after pattern")
    parser = skip_newlines(parser)

    {body, parser} = parse_compound_list(parser)

    {terminator, parser} =
      cond do
        check?(parser, :dsemi) ->
          {_token, parser} = advance(parser)
          {:dsemi, parser}

        check?(parser, :semi_and) ->
          {_token, parser} = advance(parser)
          {:semi_and, parser}

        check?(parser, :semi_semi_and) ->
          {_token, parser} = advance(parser)
          {:semi_semi_and, parser}

        true ->
          {:dsemi, parser}
      end

    parser = skip_newlines(parser)

    {AST.case_item(patterns, body, terminator), parser}
  end

  defp parse_case_patterns(parser) do
    {first_token, parser} = advance(parser)
    first_pattern = parse_word_from_token(first_token)
    parse_case_patterns_loop(parser, [first_pattern])
  end

  defp parse_case_patterns_loop(parser, patterns) do
    if check?(parser, :pipe) do
      {_token, parser} = advance(parser)
      {pattern_token, parser} = advance(parser)
      pattern = parse_word_from_token(pattern_token)
      parse_case_patterns_loop(parser, [pattern | patterns])
    else
      {Enum.reverse(patterns), parser}
    end
  end

  defp parse_subshell(parser) do
    {_token, parser} = expect(parser, :lparen)
    parser = skip_newlines(parser)

    {body, parser} = parse_compound_list(parser)

    {_token, parser} = expect(parser, :rparen, "Expected ')'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.subshell(body, redirections), parser}
  end

  defp parse_group(parser) do
    {_token, parser} = expect(parser, :lbrace)
    parser = skip_newlines(parser)

    {body, parser} = parse_compound_list(parser)

    {_token, parser} = expect(parser, :rbrace, "Expected '}'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.group(body, redirections), parser}
  end

  defp parse_arithmetic_command(parser) do
    {_token, parser} = expect(parser, :dparen_start)

    {expr_str, parser} = collect_until_dparen_end(parser, "")

    {_token, parser} = expect(parser, :dparen_end, "Expected '))'")
    {redirections, parser} = parse_redirections(parser, [])

    arith_ast = JustBash.Arithmetic.parse(expr_str)

    expression = %AST.ArithmeticExpression{
      expression: arith_ast
    }

    {AST.arithmetic_command(expression, redirections), parser}
  end

  defp collect_until_dparen_end(parser, acc) do
    if check?(parser, [:dparen_end, :eof]) do
      {acc, parser}
    else
      {token, parser} = advance(parser)
      collect_until_dparen_end(parser, acc <> token.value)
    end
  end

  defp parse_conditional_command(parser) do
    {_token, parser} = expect(parser, :dbrack_start)

    {expression, parser} = parse_conditional_expr(parser)

    {_token, parser} = expect(parser, :dbrack_end, "Expected ']]'")
    {redirections, parser} = parse_redirections(parser, [])

    {AST.conditional_command(expression, redirections), parser}
  end

  defp parse_conditional_expr(parser) do
    parse_cond_or(parser)
  end

  defp parse_cond_or(parser) do
    {left, parser} = parse_cond_and(parser)
    parse_cond_or_loop(parser, left)
  end

  defp parse_cond_or_loop(parser, left) do
    if check?(parser, [:dpipe]) do
      {_token, parser} = advance(parser)
      {right, parser} = parse_cond_and(parser)
      parse_cond_or_loop(parser, %AST.CondOr{left: left, right: right})
    else
      {left, parser}
    end
  end

  defp parse_cond_and(parser) do
    {left, parser} = parse_cond_not(parser)
    parse_cond_and_loop(parser, left)
  end

  defp parse_cond_and_loop(parser, left) do
    if check?(parser, [:damp]) do
      {_token, parser} = advance(parser)
      {right, parser} = parse_cond_not(parser)
      parse_cond_and_loop(parser, %AST.CondAnd{left: left, right: right})
    else
      {left, parser}
    end
  end

  defp parse_cond_not(parser) do
    if check_value?(parser, "!") do
      {_token, parser} = advance(parser)
      {operand, parser} = parse_cond_not(parser)
      {%AST.CondNot{operand: operand}, parser}
    else
      parse_cond_primary(parser)
    end
  end

  defp parse_cond_primary(parser) do
    cond do
      check?(parser, [:lparen]) ->
        {_token, parser} = advance(parser)
        {expr, parser} = parse_conditional_expr(parser)
        {_token, parser} = expect(parser, :rparen, "Expected ')' in conditional")
        {%AST.CondGroup{expression: expr}, parser}

      unary_cond_op?(parser) ->
        {op_token, parser} = advance(parser)
        {word, parser} = parse_cond_word(parser)
        operator = String.to_atom(op_token.value)
        {%AST.CondUnary{operator: operator, operand: word}, parser}

      true ->
        {left_word, parser} = parse_cond_word(parser)

        cond do
          check?(parser, [:dbrack_end, :damp, :dpipe, :rparen]) ->
            {%AST.CondWord{word: left_word}, parser}

          binary_cond_op?(parser) ->
            {op_token, parser} = advance(parser)
            {right_word, parser} = parse_cond_word(parser)
            operator = String.to_atom(op_token.value)
            {%AST.CondBinary{operator: operator, left: left_word, right: right_word}, parser}

          true ->
            {%AST.CondWord{word: left_word}, parser}
        end
    end
  end

  defp unary_cond_op?(parser) do
    value = current(parser).value
    value in ~w(-a -e -f -d -r -w -x -s -z -n -L -h -b -c -p -S -t -g -u -k -O -G -N -v)
  end

  defp binary_cond_op?(parser) do
    value = current(parser).value
    value in ~w(= == != =~ < > -eq -ne -lt -le -gt -ge -nt -ot -ef)
  end

  defp parse_cond_word(parser) do
    if word?(parser) do
      {token, parser} = advance(parser)
      {parse_word_from_token(token), parser}
    else
      {AST.word([]), parser}
    end
  end

  defp check_value?(parser, value) do
    current(parser).value == value
  end

  defp parse_function_def(parser) do
    {name, parser} =
      if check?(parser, :function) do
        {_token, parser} = advance(parser)
        {name_token, parser} = expect(parser, [:name, :word], "Expected function name")

        parser =
          if check?(parser, :lparen) do
            {_token, parser} = advance(parser)
            {_token, parser} = expect(parser, :rparen)
            parser
          else
            parser
          end

        {name_token.value, parser}
      else
        {name_token, parser} = advance(parser)
        {_token, parser} = expect(parser, :lparen)
        {_token, parser} = expect(parser, :rparen)
        {name_token.value, parser}
      end

    parser = skip_newlines(parser)

    {body, parser} = parse_compound_command_body(parser)
    {redirections, parser} = parse_redirections(parser, [])

    {AST.function_def(name, body, redirections), parser}
  end

  defp parse_compound_command_body(parser) do
    cond do
      check?(parser, :lbrace) -> parse_group(parser)
      check?(parser, :lparen) -> parse_subshell(parser)
      check?(parser, :if) -> parse_if(parser)
      check?(parser, :for) -> parse_for(parser)
      check?(parser, :while) -> parse_while(parser)
      check?(parser, :until) -> parse_until(parser)
      check?(parser, :case) -> parse_case(parser)
      true -> error(parser, "Expected compound command for function body")
    end
  end

  defp parse_compound_list(parser) do
    parser = skip_newlines(parser)
    parse_compound_list_loop(parser, [])
  end

  @compound_list_end_tokens [
    :eof,
    :fi,
    :else,
    :elif,
    :then,
    :do,
    :done,
    :esac,
    :rparen,
    :rbrace,
    :dsemi,
    :semi_and,
    :semi_semi_and
  ]

  defp parse_compound_list_loop(parser, statements) do
    if compound_list_end?(parser) do
      {Enum.reverse(statements), parser}
    else
      parse_next_compound_statement(parser, statements)
    end
  end

  defp compound_list_end?(parser) do
    check?(parser, @compound_list_end_tokens) or not command_start?(parser)
  end

  defp parse_next_compound_statement(parser, statements) do
    parser = check_iteration_limit(parser)
    pos_before = parser.pos

    {stmt, parser} = parse_statement(parser)
    parser = skip_separators(parser, false)

    if parser.pos == pos_before and stmt == nil do
      {Enum.reverse(statements), parser}
    else
      new_statements = append_statement(statements, stmt)
      parse_compound_list_loop(parser, new_statements)
    end
  end

  defp append_statement(statements, nil), do: statements
  defp append_statement(statements, stmt), do: [stmt | statements]
end
