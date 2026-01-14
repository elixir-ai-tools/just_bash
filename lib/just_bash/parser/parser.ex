defmodule JustBash.Parser do
  @moduledoc """
  Recursive Descent Parser for Bash Scripts.

  This parser consumes tokens from the lexer and produces an AST.
  It follows the bash grammar structure for correctness.

  Complex functionality is delegated to submodules:
  - `Parser.Compound` - if/for/while/case and other compound commands
  - `Parser.Redirection` - File redirections (>, >>, <, etc.)
  - `Parser.Heredoc` - Heredoc content handling

  Grammar (simplified):
    script       ::= statement*
    statement    ::= pipeline ((&&|'||') pipeline)*  [&]
    pipeline     ::= [!] command (| command)*
    command      ::= simple_command | compound_command | function_def
    simple_cmd   ::= (assignment)* [word] (word)* (redirection)*
    compound_cmd ::= if | for | while | until | case | subshell | group | (( | [[
  """

  alias JustBash.AST
  alias JustBash.Parser.Compound
  alias JustBash.Parser.Heredoc
  alias JustBash.Parser.Lexer
  alias JustBash.Parser.Lexer.Token
  alias JustBash.Parser.Redirection, as: RedirParser
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

  # Public API

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

  # Parser state helpers - exposed for submodules

  @doc false
  def current(parser) do
    Enum.at(parser.tokens, parser.pos) || List.last(parser.tokens)
  end

  @doc false
  def peek(parser, offset) do
    Enum.at(parser.tokens, parser.pos + offset) || List.last(parser.tokens)
  end

  @doc false
  def advance(parser) do
    token = current(parser)

    new_pos =
      if parser.pos < length(parser.tokens) - 1 do
        parser.pos + 1
      else
        parser.pos
      end

    {token, %{parser | pos: new_pos}}
  end

  @doc false
  def check?(parser, types) when is_list(types), do: current(parser).type in types
  def check?(parser, type) when is_atom(type), do: current(parser).type == type

  @doc false
  def check_value?(parser, value), do: current(parser).value == value

  @doc false
  def expect(parser, type_or_types, message \\ nil)

  def expect(parser, types, message) when is_list(types) do
    if check?(parser, types) do
      advance(parser)
    else
      token = current(parser)
      msg = message || "Expected one of #{inspect(types)}, got #{token.type}"
      raise ParseError, message: msg, line: token.line, column: token.column, token: token
    end
  end

  def expect(parser, type, message) when is_atom(type) do
    if check?(parser, type) do
      advance(parser)
    else
      token = current(parser)
      msg = message || "Expected #{type}, got #{token.type}"
      raise ParseError, message: msg, line: token.line, column: token.column, token: token
    end
  end

  @doc false
  def error(parser, message) do
    token = current(parser)
    raise ParseError, message: message, line: token.line, column: token.column, token: token
  end

  @doc false
  def skip_newlines(parser) do
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

  @doc false
  def skip_separators(parser, include_case_terminators \\ true) do
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

  @doc false
  def word?(parser) do
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

  @doc false
  def parse_word_from_token(token) do
    parts =
      WordParts.parse(
        token.value,
        quoted: token.quoted,
        single_quoted: token.single_quoted
      )

    AST.word(parts)
  end

  @doc false
  def parse_compound_list(parser), do: do_parse_compound_list(parser)

  @doc false
  def parse_redirections(parser, acc), do: RedirParser.parse_redirections(parser, acc, __MODULE__)

  defp process_heredocs(parser), do: parser

  # Script parsing

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

      new_statements = if stmt, do: [stmt | statements], else: statements
      parse_script_loop(parser, new_statements, iterations + 1)
    end
  end

  defp check_unexpected_token(parser) do
    token = current(parser)

    cond do
      token.type in [:do, :done, :then, :else, :elif, :fi, :esac] ->
        error(parser, "syntax error near unexpected token `#{token.value}'")

      token.type in [:rbrace, :rparen] ->
        error(parser, "syntax error near unexpected token `#{token.value}'")

      token.type in [:dsemi, :semi_and, :semi_semi_and] ->
        error(parser, "syntax error near unexpected token `#{token.value}'")

      token.type == :semicolon ->
        error(parser, "syntax error near unexpected token `#{token.value}'")

      true ->
        parser
    end
  end

  # Statement parsing

  defp parse_statement(parser) do
    parser = skip_newlines(parser)

    if command_start?(parser) do
      pending_before = length(parser.pending_heredocs)
      {pipelines, operators, background, parser} = parse_statement_inner(parser)
      pending_after = length(parser.pending_heredocs)

      {pipelines, parser} =
        if pending_after > pending_before do
          Heredoc.fill_heredoc_contents(pipelines, parser, __MODULE__)
        else
          {pipelines, parser}
        end

      {AST.statement(pipelines, operators, background), parser}
    else
      {nil, parser}
    end
  end

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

  # Pipeline parsing

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

  # Command dispatch

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

  defp dispatch_command(:if, parser), do: Compound.parse_if(parser, __MODULE__)
  defp dispatch_command(:for, parser), do: Compound.parse_for(parser, __MODULE__)
  defp dispatch_command(:while, parser), do: Compound.parse_while(parser, __MODULE__)
  defp dispatch_command(:until, parser), do: Compound.parse_until(parser, __MODULE__)
  defp dispatch_command(:case, parser), do: Compound.parse_case(parser, __MODULE__)
  defp dispatch_command(:subshell, parser), do: Compound.parse_subshell(parser, __MODULE__)
  defp dispatch_command(:group, parser), do: Compound.parse_group(parser, __MODULE__)

  defp dispatch_command(:arithmetic, parser),
    do: Compound.parse_arithmetic_command(parser, __MODULE__)

  defp dispatch_command(:conditional, parser),
    do: Compound.parse_conditional_command(parser, __MODULE__)

  defp dispatch_command(:function, parser), do: Compound.parse_function_def(parser, __MODULE__)
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

  # Simple command parsing

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

      if check?(parser, :lparen) do
        {assignment, parser} = parse_array_assignment(token.value, parser)
        parse_assignments(parser, [assignment | acc])
      else
        raw = token.raw_value || token.value
        assignment = parse_assignment_word(raw)
        parse_assignments(parser, [assignment | acc])
      end
    else
      {Enum.reverse(acc), parser}
    end
  end

  defp parse_array_assignment(assign_token_value, parser) do
    name = String.trim_trailing(assign_token_value, "=")
    {_lparen, parser} = advance(parser)
    {elements, parser} = parse_array_elements(parser, [])
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

  defp parse_assignment_word(raw_value) do
    case String.split(raw_value, "=", parts: 2) do
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
        AST.assignment(raw_value, nil)
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
    if word?(parser) and not statement_end?(parser) and
         not RedirParser.redirection?(parser, __MODULE__) do
      {token, parser} = advance(parser)
      word = parse_word_from_token(token)
      parse_args(parser, [word | acc])
    else
      {Enum.reverse(acc), parser}
    end
  end

  # Compound list parsing

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

  defp do_parse_compound_list(parser) do
    parser = skip_newlines(parser)
    parse_compound_list_loop(parser, [])
  end

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
      new_statements = if stmt, do: [stmt | statements], else: statements
      parse_compound_list_loop(parser, new_statements)
    end
  end

  # Helper predicates

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

  defp check_iteration_limit(parser) do
    if parser.parse_iterations > @max_parse_iterations do
      error(parser, "Maximum parse iterations exceeded (possible infinite loop)")
    end

    %{parser | parse_iterations: parser.parse_iterations + 1}
  end
end
