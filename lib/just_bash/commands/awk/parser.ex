defmodule JustBash.Commands.Awk.Parser do
  @moduledoc """
  Token-based parser for AWK programs.

  Uses recursive descent parsing on a token stream from the Lexer.
  """

  alias JustBash.Commands.Awk.AST
  alias JustBash.Commands.Awk.Lexer

  defstruct [:tokens, :pos]

  @type t :: %__MODULE__{
          tokens: [Lexer.token()],
          pos: non_neg_integer()
        }

  @doc """
  Parse an AWK program string into an AST.
  """
  @spec parse(String.t()) :: {:ok, AST.program()} | {:error, String.t()}
  def parse(input) do
    with {:ok, tokens} <- Lexer.tokenize(input) do
      state = %__MODULE__{tokens: tokens, pos: 0}
      {program, _state} = parse_program(state)
      {:ok, program}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ─── Token Helpers ─────────────────────────────────────────────

  defp current(%{tokens: tokens, pos: pos}) do
    Enum.at(tokens, pos, {:eof, "", 0, 0})
  end

  defp current_type(state), do: elem(current(state), 0)

  defp advance(%{pos: pos} = state) do
    %{state | pos: pos + 1}
  end

  defp token_is?(state, types) when is_list(types) do
    current_type(state) in types
  end

  defp token_is?(state, type) do
    current_type(state) == type
  end

  defp expect(state, type) do
    if token_is?(state, type) do
      {current(state), advance(state)}
    else
      {actual_type, actual_value, line, col} = current(state)

      raise "Expected #{type}, got #{actual_type} (#{inspect(actual_value)}) at line #{line}:#{col}"
    end
  end

  defp skip_newlines(state) do
    if token_is?(state, :newline) do
      skip_newlines(advance(state))
    else
      state
    end
  end

  defp skip_terminators(state) do
    if token_is?(state, [:newline, :semicolon]) do
      skip_terminators(advance(state))
    else
      state
    end
  end

  # ─── Program Parsing ───────────────────────────────────────────

  defp parse_program(state) do
    state = skip_newlines(state)
    parse_program_rules(state, [], [])
  end

  defp parse_program_rules(state, rules, functions) do
    state = skip_newlines(state)

    case current_type(state) do
      :eof ->
        {AST.program(Enum.reverse(rules), Enum.reverse(functions)), state}

      :function ->
        {func, state} = parse_function(state)
        state = skip_terminators(state)
        parse_program_rules(state, rules, [func | functions])

      _ ->
        {rule, state} = parse_rule(state)
        state = skip_terminators(state)
        parse_program_rules(state, [rule | rules], functions)
    end
  end

  defp parse_function(state) do
    {_, state} = expect(state, :function)
    {name_token, state} = expect(state, :ident)
    name = elem(name_token, 1)
    {_, state} = expect(state, :lparen)

    {params, state} = parse_function_params(state)

    {_, state} = expect(state, :rparen)
    state = skip_newlines(state)
    {body, state} = parse_block(state)

    {%{name: name, params: params, body: body}, state}
  end

  defp parse_function_params(state) do
    if token_is?(state, :rparen) do
      {[], state}
    else
      {first, state} = expect(state, :ident)
      parse_function_params_rest(state, [elem(first, 1)])
    end
  end

  defp parse_function_params_rest(state, acc) do
    if token_is?(state, :comma) do
      state = advance(state)
      {param, state} = expect(state, :ident)
      parse_function_params_rest(state, [elem(param, 1) | acc])
    else
      {Enum.reverse(acc), state}
    end
  end

  defp parse_rule(state) do
    {pattern, state} = parse_pattern(state)
    state = skip_newlines(state)

    {action, state} =
      if token_is?(state, :lbrace) do
        parse_block(state)
      else
        # Default action is print $0
        {AST.block([AST.print([AST.field(AST.number(0))], nil)]), state}
      end

    {AST.rule(pattern, action), state}
  end

  defp parse_pattern(state) do
    case current_type(state) do
      :begin ->
        {_, state} = expect(state, :begin)
        {:begin, state}

      :end ->
        {_, state} = expect(state, :end)
        {:end, state}

      :lbrace ->
        # No pattern, just action
        {nil, state}

      :regex ->
        {token, state} = expect(state, :regex)
        pattern = {:regex, elem(token, 1)}
        # Check for range pattern
        parse_range_pattern(state, pattern)

      _ ->
        # Expression pattern
        {expr, state} = parse_expression(state)
        pattern = {:expr, expr}
        parse_range_pattern(state, pattern)
    end
  end

  defp parse_range_pattern(state, start_pattern) do
    if token_is?(state, :comma) do
      state = advance(state)

      {end_pattern, state} =
        if token_is?(state, :regex) do
          {token, state} = expect(state, :regex)
          {{:regex, elem(token, 1)}, state}
        else
          {expr, state} = parse_expression(state)
          {{:expr, expr}, state}
        end

      {{:range, start_pattern, end_pattern}, state}
    else
      {start_pattern, state}
    end
  end

  defp parse_block(state) do
    {_, state} = expect(state, :lbrace)
    state = skip_newlines(state)

    {statements, state} = parse_block_statements(state, [])

    {_, state} = expect(state, :rbrace)
    {AST.block(statements), state}
  end

  defp parse_block_statements(state, acc) do
    state = skip_newlines(state)

    if token_is?(state, [:rbrace, :eof]) do
      {Enum.reverse(acc), state}
    else
      {stmt, state} = parse_statement(state)
      state = skip_terminators(state)
      parse_block_statements(state, [stmt | acc])
    end
  end

  # ─── Statement Parsing ─────────────────────────────────────────

  defp parse_statement(state) do
    # Skip empty statements
    if token_is?(state, [:semicolon, :newline]) do
      {AST.block([]), advance(state)}
    else
      do_parse_statement(state)
    end
  end

  defp do_parse_statement(state) do
    case current_type(state) do
      :lbrace ->
        parse_block(state)

      :if ->
        parse_if(state)

      :while ->
        parse_while(state)

      :do ->
        parse_do_while(state)

      :for ->
        parse_for(state)

      :break ->
        {_, state} = expect(state, :break)
        {{:break}, state}

      :continue ->
        {_, state} = expect(state, :continue)
        {{:continue}, state}

      :next ->
        {_, state} = expect(state, :next)
        {{:next}, state}

      :exit ->
        parse_exit(state)

      :return ->
        parse_return(state)

      :delete ->
        parse_delete(state)

      :print ->
        parse_print(state)

      :printf ->
        parse_printf(state)

      _ ->
        # Expression statement
        {expr, state} = parse_expression(state)
        {AST.expr_stmt(expr), state}
    end
  end

  defp parse_if(state) do
    {_, state} = expect(state, :if)
    {_, state} = expect(state, :lparen)
    {condition, state} = parse_expression(state)
    {_, state} = expect(state, :rparen)
    state = skip_newlines(state)
    {consequent, state} = parse_statement(state)
    state = skip_terminators(state)

    {alternate, state} =
      if token_is?(state, :else) do
        state = advance(state)
        state = skip_newlines(state)
        {alt, state} = parse_statement(state)
        {alt, state}
      else
        {nil, state}
      end

    {AST.if_stmt(condition, consequent, alternate), state}
  end

  defp parse_while(state) do
    {_, state} = expect(state, :while)
    {_, state} = expect(state, :lparen)
    {condition, state} = parse_expression(state)
    {_, state} = expect(state, :rparen)
    state = skip_newlines(state)
    {body, state} = parse_statement(state)

    {AST.while_stmt(condition, body), state}
  end

  defp parse_do_while(state) do
    {_, state} = expect(state, :do)
    state = skip_newlines(state)
    {body, state} = parse_statement(state)
    state = skip_newlines(state)
    {_, state} = expect(state, :while)
    {_, state} = expect(state, :lparen)
    {condition, state} = parse_expression(state)
    {_, state} = expect(state, :rparen)

    {AST.do_while(body, condition), state}
  end

  defp parse_for(state) do
    {_, state} = expect(state, :for)
    {_, state} = expect(state, :lparen)

    # Check for for-in: for (var in array)
    if token_is?(state, :ident) do
      saved_state = state
      {var_token, state} = expect(state, :ident)

      if token_is?(state, :in) do
        state = advance(state)
        {array_token, state} = expect(state, :ident)
        {_, state} = expect(state, :rparen)
        state = skip_newlines(state)
        {body, state} = parse_statement(state)
        {AST.for_in(elem(var_token, 1), elem(array_token, 1), body), state}
      else
        # Not for-in, backtrack and parse C-style for
        parse_c_style_for(saved_state)
      end
    else
      parse_c_style_for(state)
    end
  end

  defp parse_c_style_for(state) do
    {init, state} =
      if token_is?(state, :semicolon) do
        {nil, state}
      else
        {expr, state} = parse_expression(state)
        {expr, state}
      end

    {_, state} = expect(state, :semicolon)

    {condition, state} =
      if token_is?(state, :semicolon) do
        {nil, state}
      else
        parse_expression(state)
      end

    {_, state} = expect(state, :semicolon)

    {update, state} =
      if token_is?(state, :rparen) do
        {nil, state}
      else
        parse_expression(state)
      end

    {_, state} = expect(state, :rparen)
    state = skip_newlines(state)
    {body, state} = parse_statement(state)

    {AST.for_stmt(init, condition, update, body), state}
  end

  defp parse_exit(state) do
    {_, state} = expect(state, :exit)

    {code, state} =
      if statement_terminator?(state) do
        {nil, state}
      else
        parse_expression(state)
      end

    {AST.exit_stmt(code), state}
  end

  defp parse_return(state) do
    {_, state} = expect(state, :return)

    {value, state} =
      if statement_terminator?(state) do
        {nil, state}
      else
        parse_expression(state)
      end

    {AST.return_stmt(value), state}
  end

  defp statement_terminator?(state) do
    token_is?(state, [:newline, :semicolon, :rbrace, :eof])
  end

  defp parse_delete(state) do
    {_, state} = expect(state, :delete)
    {target, state} = parse_primary(state)
    {AST.delete(target), state}
  end

  defp parse_print(state) do
    {_, state} = expect(state, :print)

    {args, state} =
      if print_terminator?(state) do
        {[AST.field(AST.number(0))], state}
      else
        parse_print_args(state)
      end

    {output, state} = parse_output_redirect(state)

    {AST.print(args, output), state}
  end

  defp parse_printf(state) do
    {_, state} = expect(state, :printf)

    # printf can be: printf format, arg1, arg2 OR printf(format, arg1, arg2)
    {has_parens, state} =
      if token_is?(state, :lparen) do
        {true, advance(state)}
      else
        {false, state}
      end

    state = if has_parens, do: skip_newlines(state), else: state

    {format, state} = parse_print_arg(state)
    {args, state} = parse_printf_args(state, has_parens)

    state =
      if has_parens do
        state = skip_newlines(state)
        {_, state} = expect(state, :rparen)
        state
      else
        state
      end

    {output, state} = parse_output_redirect(state)

    {AST.printf(format, args, output), state}
  end

  defp parse_printf_args(state, has_parens) do
    if token_is?(state, :comma) do
      state = advance(state)
      state = if has_parens, do: skip_newlines(state), else: state
      {arg, state} = parse_print_arg(state)
      {rest, state} = parse_printf_args(state, has_parens)
      {[arg | rest], state}
    else
      {[], state}
    end
  end

  defp print_terminator?(state) do
    token_is?(state, [:newline, :semicolon, :rbrace, :pipe, :gt, :append])
  end

  defp parse_print_args(state) do
    {first, state} = parse_print_arg(state)
    parse_print_args_rest(state, [first])
  end

  defp parse_print_args_rest(state, acc) do
    if token_is?(state, :comma) do
      state = advance(state)
      {arg, state} = parse_print_arg(state)
      parse_print_args_rest(state, [arg | acc])
    else
      {Enum.reverse(acc), state}
    end
  end

  defp parse_print_arg(state) do
    # In print context, > and >> are redirection, not comparison
    # So we parse a limited expression that stops at those
    parse_ternary(state)
  end

  defp parse_output_redirect(state) do
    cond do
      token_is?(state, :gt) ->
        state = advance(state)
        {file, state} = parse_primary(state)
        {{:redirect, :gt, file}, state}

      token_is?(state, :append) ->
        state = advance(state)
        {file, state} = parse_primary(state)
        {{:redirect, :append, file}, state}

      true ->
        {nil, state}
    end
  end

  # ─── Expression Parsing (Precedence Climbing) ──────────────────

  defp parse_expression(state) do
    parse_assignment(state)
  end

  defp parse_assignment(state) do
    {expr, state} = parse_ternary(state)

    if token_is?(state, [
         :assign,
         :plus_assign,
         :minus_assign,
         :star_assign,
         :slash_assign,
         :percent_assign,
         :caret_assign
       ]) do
      op = assignment_op(current_type(state))
      state = advance(state)
      {value, state} = parse_assignment(state)
      {AST.assign(op, expr, value), state}
    else
      {expr, state}
    end
  end

  defp assignment_op(:assign), do: :assign
  defp assignment_op(:plus_assign), do: :add_assign
  defp assignment_op(:minus_assign), do: :sub_assign
  defp assignment_op(:star_assign), do: :mul_assign
  defp assignment_op(:slash_assign), do: :div_assign
  defp assignment_op(:percent_assign), do: :mod_assign
  defp assignment_op(:caret_assign), do: :pow_assign

  defp parse_ternary(state) do
    {cond_expr, state} = parse_or(state)

    if token_is?(state, :question) do
      state = advance(state)
      {consequent, state} = parse_expression(state)
      {_, state} = expect(state, :colon)
      {alternate, state} = parse_expression(state)
      {AST.ternary(cond_expr, consequent, alternate), state}
    else
      {cond_expr, state}
    end
  end

  defp parse_or(state) do
    {left, state} = parse_and(state)
    parse_or_rest(state, left)
  end

  defp parse_or_rest(state, left) do
    if token_is?(state, :or) do
      state = advance(state)
      {right, state} = parse_and(state)
      parse_or_rest(state, AST.binary(:or, left, right))
    else
      {left, state}
    end
  end

  defp parse_and(state) do
    {left, state} = parse_in(state)
    parse_and_rest(state, left)
  end

  defp parse_and_rest(state, left) do
    if token_is?(state, :and) do
      state = advance(state)
      {right, state} = parse_in(state)
      parse_and_rest(state, AST.binary(:and, left, right))
    else
      {left, state}
    end
  end

  defp parse_in(state) do
    {left, state} = parse_match(state)

    if token_is?(state, :in) do
      state = advance(state)
      {array_token, state} = expect(state, :ident)
      {AST.in_expr(left, elem(array_token, 1)), state}
    else
      {left, state}
    end
  end

  defp parse_match(state) do
    {left, state} = parse_comparison(state)
    parse_match_rest(state, left)
  end

  defp parse_match_rest(state, left) do
    cond do
      token_is?(state, :match) ->
        state = advance(state)
        {right, state} = parse_comparison(state)
        parse_match_rest(state, AST.binary(:match, left, right))

      token_is?(state, :not_match) ->
        state = advance(state)
        {right, state} = parse_comparison(state)
        parse_match_rest(state, AST.binary(:not_match, left, right))

      true ->
        {left, state}
    end
  end

  defp parse_comparison(state) do
    {left, state} = parse_concat(state)
    parse_comparison_rest(state, left)
  end

  defp parse_comparison_rest(state, left) do
    cond do
      token_is?(state, :lt) ->
        state = advance(state)
        {right, state} = parse_concat(state)
        parse_comparison_rest(state, AST.binary(:lt, left, right))

      token_is?(state, :le) ->
        state = advance(state)
        {right, state} = parse_concat(state)
        parse_comparison_rest(state, AST.binary(:le, left, right))

      token_is?(state, :gt) ->
        state = advance(state)
        {right, state} = parse_concat(state)
        parse_comparison_rest(state, AST.binary(:gt, left, right))

      token_is?(state, :ge) ->
        state = advance(state)
        {right, state} = parse_concat(state)
        parse_comparison_rest(state, AST.binary(:ge, left, right))

      token_is?(state, :eq) ->
        state = advance(state)
        {right, state} = parse_concat(state)
        parse_comparison_rest(state, AST.binary(:eq, left, right))

      token_is?(state, :ne) ->
        state = advance(state)
        {right, state} = parse_concat(state)
        parse_comparison_rest(state, AST.binary(:ne, left, right))

      true ->
        {left, state}
    end
  end

  defp parse_concat(state) do
    {left, state} = parse_add_sub(state)
    parse_concat_rest(state, left)
  end

  defp parse_concat_rest(state, left) do
    # Concatenation is implicit - consecutive expressions without operators
    if can_start_expression?(state) and not concat_terminator?(state) do
      {right, state} = parse_add_sub(state)
      parse_concat_rest(state, AST.binary(:concat, left, right))
    else
      {left, state}
    end
  end

  defp can_start_expression?(state) do
    token_is?(state, [
      :number,
      :string,
      :ident,
      :dollar,
      :lparen,
      :not,
      :minus,
      :plus,
      :increment,
      :decrement
    ])
  end

  defp concat_terminator?(state) do
    token_is?(state, [
      :and,
      :or,
      :question,
      :assign,
      :plus_assign,
      :minus_assign,
      :star_assign,
      :slash_assign,
      :percent_assign,
      :caret_assign,
      :comma,
      :semicolon,
      :newline,
      :rbrace,
      :rparen,
      :rbracket,
      :colon,
      :pipe,
      :append,
      :in,
      :gt,
      :eof
    ])
  end

  defp parse_add_sub(state) do
    {left, state} = parse_mul_div(state)
    parse_add_sub_rest(state, left)
  end

  defp parse_add_sub_rest(state, left) do
    cond do
      token_is?(state, :plus) ->
        state = advance(state)
        {right, state} = parse_mul_div(state)
        parse_add_sub_rest(state, AST.binary(:add, left, right))

      token_is?(state, :minus) ->
        state = advance(state)
        {right, state} = parse_mul_div(state)
        parse_add_sub_rest(state, AST.binary(:sub, left, right))

      true ->
        {left, state}
    end
  end

  defp parse_mul_div(state) do
    {left, state} = parse_unary(state)
    parse_mul_div_rest(state, left)
  end

  defp parse_mul_div_rest(state, left) do
    cond do
      token_is?(state, :star) ->
        state = advance(state)
        {right, state} = parse_unary(state)
        parse_mul_div_rest(state, AST.binary(:mul, left, right))

      token_is?(state, :slash) ->
        state = advance(state)
        {right, state} = parse_unary(state)
        parse_mul_div_rest(state, AST.binary(:div, left, right))

      token_is?(state, :percent) ->
        state = advance(state)
        {right, state} = parse_unary(state)
        parse_mul_div_rest(state, AST.binary(:mod, left, right))

      true ->
        {left, state}
    end
  end

  defp parse_unary(state) do
    cond do
      token_is?(state, :increment) ->
        state = advance(state)
        {operand, state} = parse_unary(state)
        {AST.pre_inc(operand), state}

      token_is?(state, :decrement) ->
        state = advance(state)
        {operand, state} = parse_unary(state)
        {AST.pre_dec(operand), state}

      token_is?(state, :not) ->
        state = advance(state)
        {operand, state} = parse_unary(state)
        {AST.unary(:not, operand), state}

      token_is?(state, :minus) ->
        state = advance(state)
        {operand, state} = parse_unary(state)
        {AST.unary(:negate, operand), state}

      token_is?(state, :plus) ->
        state = advance(state)
        {operand, state} = parse_unary(state)
        {AST.unary(:plus, operand), state}

      true ->
        parse_power(state)
    end
  end

  defp parse_power(state) do
    {left, state} = parse_postfix(state)

    if token_is?(state, :caret) do
      state = advance(state)
      # Power is right-associative
      {right, state} = parse_power(state)
      {AST.binary(:pow, left, right), state}
    else
      {left, state}
    end
  end

  defp parse_postfix(state) do
    {expr, state} = parse_primary(state)
    parse_postfix_ops(state, expr)
  end

  defp parse_postfix_ops(state, expr) do
    cond do
      token_is?(state, :increment) ->
        state = advance(state)
        parse_postfix_ops(state, AST.post_inc(expr))

      token_is?(state, :decrement) ->
        state = advance(state)
        parse_postfix_ops(state, AST.post_dec(expr))

      true ->
        {expr, state}
    end
  end

  defp parse_primary(state) do
    case current_type(state) do
      :number ->
        {token, state} = expect(state, :number)
        {AST.number(elem(token, 1)), state}

      :string ->
        {token, state} = expect(state, :string)
        {AST.string(elem(token, 1)), state}

      :regex ->
        {token, state} = expect(state, :regex)
        {AST.regex(elem(token, 1)), state}

      :dollar ->
        state = advance(state)
        {index, state} = parse_unary(state)
        {AST.field(index), state}

      :lparen ->
        state = advance(state)
        {expr, state} = parse_expression(state)
        {_, state} = expect(state, :rparen)
        {expr, state}

      :ident ->
        {token, state} = expect(state, :ident)
        name = elem(token, 1)
        parse_ident_suffix(state, name)

      :getline ->
        parse_getline(state)

      _ ->
        {type, value, line, col} = current(state)
        raise "Unexpected token: #{type} (#{inspect(value)}) at line #{line}:#{col}"
    end
  end

  defp parse_ident_suffix(state, name) do
    cond do
      token_is?(state, :lparen) ->
        # Function call
        state = advance(state)
        state = skip_newlines(state)
        {args, state} = parse_call_args(state)
        state = skip_newlines(state)
        {_, state} = expect(state, :rparen)
        {AST.call(name, args), state}

      token_is?(state, :lbracket) ->
        # Array access
        state = advance(state)
        {key, state} = parse_array_key(state)
        {_, state} = expect(state, :rbracket)
        {AST.array_access(name, key), state}

      true ->
        # Simple variable
        {AST.variable(name), state}
    end
  end

  defp parse_call_args(state) do
    if token_is?(state, :rparen) do
      {[], state}
    else
      {first, state} = parse_expression(state)
      parse_call_args_rest(state, [first])
    end
  end

  defp parse_call_args_rest(state, acc) do
    if token_is?(state, :comma) do
      state = advance(state)
      state = skip_newlines(state)
      {arg, state} = parse_expression(state)
      parse_call_args_rest(state, [arg | acc])
    else
      {Enum.reverse(acc), state}
    end
  end

  defp parse_array_key(state) do
    # Handle multi-dimensional array: a[1,2,3]
    {first, state} = parse_expression(state)

    if token_is?(state, :comma) do
      parse_multi_key(state, [first])
    else
      {first, state}
    end
  end

  defp parse_multi_key(state, acc) do
    if token_is?(state, :comma) do
      state = advance(state)
      {key, state} = parse_expression(state)
      parse_multi_key(state, [key | acc])
    else
      # Concatenate keys with SUBSEP
      keys = Enum.reverse(acc)

      combined =
        Enum.reduce(tl(keys), hd(keys), fn key, acc ->
          AST.binary(:concat, AST.binary(:concat, acc, AST.variable("SUBSEP")), key)
        end)

      {combined, state}
    end
  end

  defp parse_getline(state) do
    {_, state} = expect(state, :getline)

    {variable, state} =
      if token_is?(state, :ident) do
        {token, state} = expect(state, :ident)
        {elem(token, 1), state}
      else
        {nil, state}
      end

    {file, state} =
      if token_is?(state, :lt) do
        state = advance(state)
        {expr, state} = parse_primary(state)
        {expr, state}
      else
        {nil, state}
      end

    {{:getline, variable, file, nil}, state}
  end
end
