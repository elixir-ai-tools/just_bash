defmodule JustBash.Parser.Compound do
  @moduledoc """
  Parser for compound commands in bash.

  Handles parsing of:
  - `if`/`elif`/`else`/`fi` conditionals
  - `for`/`while`/`until` loops
  - `case`/`esac` pattern matching
  - Subshells `(...)` and groups `{...}`
  - Arithmetic `((...))` and conditional `[[...]]` commands
  - Function definitions
  """

  alias JustBash.AST

  @doc """
  Parse an if/elif/else/fi construct.
  """
  def parse_if(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :if)
    parser = helpers.skip_newlines(parser)

    {condition, parser} = helpers.parse_compound_list(parser)
    {_token, parser} = helpers.expect(parser, :then, "Expected 'then'")
    parser = helpers.skip_newlines(parser)

    {body, parser} = helpers.parse_compound_list(parser)
    first_clause = AST.if_clause(condition, body)

    {clauses, else_body, parser} = parse_elif_else(parser, [first_clause], helpers)

    {_token, parser} = helpers.expect(parser, :fi, "Expected 'fi'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.if_node(clauses, else_body, redirections), parser}
  end

  defp parse_elif_else(parser, clauses, helpers) do
    cond do
      helpers.check?(parser, :elif) ->
        {_token, parser} = helpers.advance(parser)
        parser = helpers.skip_newlines(parser)
        {condition, parser} = helpers.parse_compound_list(parser)
        {_token, parser} = helpers.expect(parser, :then, "Expected 'then'")
        parser = helpers.skip_newlines(parser)
        {body, parser} = helpers.parse_compound_list(parser)
        new_clause = AST.if_clause(condition, body)
        parse_elif_else(parser, [new_clause | clauses], helpers)

      helpers.check?(parser, :else) ->
        {_token, parser} = helpers.advance(parser)
        parser = helpers.skip_newlines(parser)
        {else_body, parser} = helpers.parse_compound_list(parser)
        {Enum.reverse(clauses), else_body, parser}

      true ->
        {Enum.reverse(clauses), nil, parser}
    end
  end

  @doc """
  Parse a for loop construct.
  """
  def parse_for(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :for)
    parser = helpers.skip_newlines(parser)

    {var_token, parser} = helpers.expect(parser, [:name, :word], "Expected variable name")
    variable = var_token.value

    parser = helpers.skip_newlines(parser)

    {words, parser} =
      if helpers.check?(parser, :in) do
        {_token, parser} = helpers.advance(parser)
        {word_list, parser} = parse_word_list(parser, helpers)
        {word_list, parser}
      else
        {nil, parser}
      end

    parser = helpers.skip_separators(parser)
    {_token, parser} = helpers.expect(parser, :do, "Expected 'do'")
    parser = helpers.skip_newlines(parser)

    {body, parser} = helpers.parse_compound_list(parser)

    {_token, parser} = helpers.expect(parser, :done, "Expected 'done'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.for_node(variable, words, body, redirections), parser}
  end

  defp parse_word_list(parser, helpers) do
    parse_word_list_loop(parser, [], helpers)
  end

  defp parse_word_list_loop(parser, acc, helpers) do
    if helpers.word?(parser) and not helpers.check?(parser, [:semicolon, :newline, :do]) do
      {token, parser} = helpers.advance(parser)
      word = helpers.parse_word_from_token(token)
      parse_word_list_loop(parser, [word | acc], helpers)
    else
      {Enum.reverse(acc), parser}
    end
  end

  @doc """
  Parse a while loop construct.
  """
  def parse_while(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :while)
    parser = helpers.skip_newlines(parser)

    {condition, parser} = helpers.parse_compound_list(parser)
    {_token, parser} = helpers.expect(parser, :do, "Expected 'do'")
    parser = helpers.skip_newlines(parser)

    {body, parser} = helpers.parse_compound_list(parser)

    {_token, parser} = helpers.expect(parser, :done, "Expected 'done'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.while_node(condition, body, redirections), parser}
  end

  @doc """
  Parse an until loop construct.
  """
  def parse_until(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :until)
    parser = helpers.skip_newlines(parser)

    {condition, parser} = helpers.parse_compound_list(parser)
    {_token, parser} = helpers.expect(parser, :do, "Expected 'do'")
    parser = helpers.skip_newlines(parser)

    {body, parser} = helpers.parse_compound_list(parser)

    {_token, parser} = helpers.expect(parser, :done, "Expected 'done'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.until_node(condition, body, redirections), parser}
  end

  @doc """
  Parse a case/esac construct.
  """
  def parse_case(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :case)
    parser = helpers.skip_newlines(parser)

    {word_token, parser} = helpers.advance(parser)
    word = helpers.parse_word_from_token(word_token)

    parser = helpers.skip_newlines(parser)
    {_token, parser} = helpers.expect(parser, :in, "Expected 'in'")
    parser = helpers.skip_newlines(parser)

    {items, parser} = parse_case_items(parser, [], helpers)

    {_token, parser} = helpers.expect(parser, :esac, "Expected 'esac'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.case_node(word, items, redirections), parser}
  end

  defp parse_case_items(parser, acc, helpers) do
    parser = helpers.skip_newlines(parser)

    if helpers.check?(parser, :esac) do
      {Enum.reverse(acc), parser}
    else
      {item, parser} = parse_case_item(parser, helpers)
      parse_case_items(parser, [item | acc], helpers)
    end
  end

  defp parse_case_item(parser, helpers) do
    parser =
      if helpers.check?(parser, :lparen) do
        {_token, parser} = helpers.advance(parser)
        parser
      else
        parser
      end

    {patterns, parser} = parse_case_patterns(parser, helpers)
    {_token, parser} = helpers.expect(parser, :rparen, "Expected ')' after pattern")
    parser = helpers.skip_newlines(parser)

    {body, parser} = helpers.parse_compound_list(parser)

    {terminator, parser} =
      cond do
        helpers.check?(parser, :dsemi) ->
          {_token, parser} = helpers.advance(parser)
          {:dsemi, parser}

        helpers.check?(parser, :semi_and) ->
          {_token, parser} = helpers.advance(parser)
          {:semi_and, parser}

        helpers.check?(parser, :semi_semi_and) ->
          {_token, parser} = helpers.advance(parser)
          {:semi_semi_and, parser}

        true ->
          {:dsemi, parser}
      end

    parser = helpers.skip_newlines(parser)

    {AST.case_item(patterns, body, terminator), parser}
  end

  defp parse_case_patterns(parser, helpers) do
    {first_token, parser} = helpers.advance(parser)
    first_pattern = helpers.parse_word_from_token(first_token)
    parse_case_patterns_loop(parser, [first_pattern], helpers)
  end

  defp parse_case_patterns_loop(parser, patterns, helpers) do
    if helpers.check?(parser, :pipe) do
      {_token, parser} = helpers.advance(parser)
      {pattern_token, parser} = helpers.advance(parser)
      pattern = helpers.parse_word_from_token(pattern_token)
      parse_case_patterns_loop(parser, [pattern | patterns], helpers)
    else
      {Enum.reverse(patterns), parser}
    end
  end

  @doc """
  Parse a subshell `(...)`.
  """
  def parse_subshell(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :lparen)
    parser = helpers.skip_newlines(parser)

    {body, parser} = helpers.parse_compound_list(parser)

    {_token, parser} = helpers.expect(parser, :rparen, "Expected ')'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.subshell(body, redirections), parser}
  end

  @doc """
  Parse a group `{...}`.
  """
  def parse_group(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :lbrace)
    parser = helpers.skip_newlines(parser)

    {body, parser} = helpers.parse_compound_list(parser)

    {_token, parser} = helpers.expect(parser, :rbrace, "Expected '}'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.group(body, redirections), parser}
  end

  @doc """
  Parse an arithmetic command `((...))`.
  """
  def parse_arithmetic_command(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :dparen_start)

    {expr_str, parser} = collect_until_dparen_end(parser, "", helpers)

    {_token, parser} = helpers.expect(parser, :dparen_end, "Expected '))'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    arith_ast = JustBash.Arithmetic.parse(expr_str)

    expression = %AST.ArithmeticExpression{
      expression: arith_ast
    }

    {AST.arithmetic_command(expression, redirections), parser}
  end

  defp collect_until_dparen_end(parser, acc, helpers) do
    if helpers.check?(parser, [:dparen_end, :eof]) do
      {acc, parser}
    else
      {token, parser} = helpers.advance(parser)
      collect_until_dparen_end(parser, acc <> token.value, helpers)
    end
  end

  @doc """
  Parse a conditional command `[[...]]`.
  """
  def parse_conditional_command(parser, helpers) do
    {_token, parser} = helpers.expect(parser, :dbrack_start)

    {expression, parser} = parse_conditional_expr(parser, helpers)

    {_token, parser} = helpers.expect(parser, :dbrack_end, "Expected ']]'")
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.conditional_command(expression, redirections), parser}
  end

  defp parse_conditional_expr(parser, helpers) do
    parse_cond_or(parser, helpers)
  end

  defp parse_cond_or(parser, helpers) do
    {left, parser} = parse_cond_and(parser, helpers)
    parse_cond_or_loop(parser, left, helpers)
  end

  defp parse_cond_or_loop(parser, left, helpers) do
    if helpers.check?(parser, [:dpipe]) do
      {_token, parser} = helpers.advance(parser)
      {right, parser} = parse_cond_and(parser, helpers)
      parse_cond_or_loop(parser, %AST.CondOr{left: left, right: right}, helpers)
    else
      {left, parser}
    end
  end

  defp parse_cond_and(parser, helpers) do
    {left, parser} = parse_cond_not(parser, helpers)
    parse_cond_and_loop(parser, left, helpers)
  end

  defp parse_cond_and_loop(parser, left, helpers) do
    if helpers.check?(parser, [:damp]) do
      {_token, parser} = helpers.advance(parser)
      {right, parser} = parse_cond_not(parser, helpers)
      parse_cond_and_loop(parser, %AST.CondAnd{left: left, right: right}, helpers)
    else
      {left, parser}
    end
  end

  defp parse_cond_not(parser, helpers) do
    if helpers.check_value?(parser, "!") do
      {_token, parser} = helpers.advance(parser)
      {operand, parser} = parse_cond_not(parser, helpers)
      {%AST.CondNot{operand: operand}, parser}
    else
      parse_cond_primary(parser, helpers)
    end
  end

  defp parse_cond_primary(parser, helpers) do
    cond do
      helpers.check?(parser, [:lparen]) ->
        {_token, parser} = helpers.advance(parser)
        {expr, parser} = parse_conditional_expr(parser, helpers)
        {_token, parser} = helpers.expect(parser, :rparen, "Expected ')' in conditional")
        {%AST.CondGroup{expression: expr}, parser}

      unary_cond_op?(parser, helpers) ->
        {op_token, parser} = helpers.advance(parser)
        {word, parser} = parse_cond_word(parser, helpers)
        operator = String.to_atom(op_token.value)
        {%AST.CondUnary{operator: operator, operand: word}, parser}

      true ->
        {left_word, parser} = parse_cond_word(parser, helpers)

        cond do
          helpers.check?(parser, [:dbrack_end, :damp, :dpipe, :rparen]) ->
            {%AST.CondWord{word: left_word}, parser}

          binary_cond_op?(parser, helpers) ->
            {op_token, parser} = helpers.advance(parser)
            {right_word, parser} = parse_cond_word(parser, helpers)
            operator = String.to_atom(op_token.value)
            {%AST.CondBinary{operator: operator, left: left_word, right: right_word}, parser}

          true ->
            {%AST.CondWord{word: left_word}, parser}
        end
    end
  end

  @unary_ops ~w(-a -e -f -d -r -w -x -s -z -n -L -h -b -c -p -S -t -g -u -k -O -G -N -v)
  @binary_ops ~w(= == != =~ < > -eq -ne -lt -le -gt -ge -nt -ot -ef)

  defp unary_cond_op?(parser, helpers) do
    helpers.current(parser).value in @unary_ops
  end

  defp binary_cond_op?(parser, helpers) do
    helpers.current(parser).value in @binary_ops
  end

  defp parse_cond_word(parser, helpers) do
    if helpers.word?(parser) do
      {token, parser} = helpers.advance(parser)
      {helpers.parse_word_from_token(token), parser}
    else
      {AST.word([]), parser}
    end
  end

  @doc """
  Parse a function definition.
  """
  def parse_function_def(parser, helpers) do
    {name, parser} =
      if helpers.check?(parser, :function) do
        {_token, parser} = helpers.advance(parser)
        {name_token, parser} = helpers.expect(parser, [:name, :word], "Expected function name")

        parser =
          if helpers.check?(parser, :lparen) do
            {_token, parser} = helpers.advance(parser)
            {_token, parser} = helpers.expect(parser, :rparen)
            parser
          else
            parser
          end

        {name_token.value, parser}
      else
        {name_token, parser} = helpers.advance(parser)
        {_token, parser} = helpers.expect(parser, :lparen)
        {_token, parser} = helpers.expect(parser, :rparen)
        {name_token.value, parser}
      end

    parser = helpers.skip_newlines(parser)

    {body, parser} = parse_compound_command_body(parser, helpers)
    {redirections, parser} = helpers.parse_redirections(parser, [])

    {AST.function_def(name, body, redirections), parser}
  end

  defp parse_compound_command_body(parser, helpers) do
    cond do
      helpers.check?(parser, :lbrace) -> parse_group(parser, helpers)
      helpers.check?(parser, :lparen) -> parse_subshell(parser, helpers)
      helpers.check?(parser, :if) -> parse_if(parser, helpers)
      helpers.check?(parser, :for) -> parse_for(parser, helpers)
      helpers.check?(parser, :while) -> parse_while(parser, helpers)
      helpers.check?(parser, :until) -> parse_until(parser, helpers)
      helpers.check?(parser, :case) -> parse_case(parser, helpers)
      true -> helpers.error(parser, "Expected compound command for function body")
    end
  end
end
