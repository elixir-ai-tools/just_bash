defmodule JustBash.Formatter do
  @moduledoc """
  Bash code formatter.

  Converts a bash AST back into formatted bash source code.
  This enables parsing bash scripts and outputting them in a
  consistent, readable format.

  ## Usage

      {:ok, ast} = JustBash.parse("echo   hello    world")
      formatted = JustBash.Formatter.format(ast)
      # "echo hello world"

  ## Options

  - `:indent` - Indentation string (default: "  " - two spaces)
  - `:max_line_length` - Maximum line length for wrapping (default: 80)
  """

  alias JustBash.AST

  @default_indent "  "

  @type option :: {:indent, String.t()} | {:max_line_length, pos_integer()}
  @type options :: [option()]

  @doc """
  Format an AST into bash source code.

  ## Examples

      {:ok, ast} = JustBash.parse("if true; then echo yes; fi")
      JustBash.Formatter.format(ast)
      # "if true; then\\n  echo yes\\nfi"
  """
  @spec format(AST.Script.t(), options()) :: String.t()
  def format(%AST.Script{} = script, opts \\ []) do
    ctx = %{
      indent: Keyword.get(opts, :indent, @default_indent),
      level: 0
    }

    script.statements
    |> Enum.map(&format_statement(&1, ctx))
    |> Enum.join("\n")
  end

  # Statement: pipelines connected by && or ||
  defp format_statement(%AST.Statement{} = stmt, ctx) do
    parts =
      stmt.pipelines
      |> Enum.zip(stmt.operators ++ [nil])
      |> Enum.map(fn {pipeline, op} ->
        formatted = format_pipeline(pipeline, ctx)

        case op do
          :and -> formatted <> " &&"
          :or -> formatted <> " ||"
          :semi -> formatted <> ";"
          nil -> formatted
        end
      end)
      |> Enum.join(" ")

    if stmt.background do
      parts <> " &"
    else
      parts
    end
  end

  # Pipeline: cmd1 | cmd2 | cmd3
  defp format_pipeline(%AST.Pipeline{} = pipeline, ctx) do
    prefix = if pipeline.negated, do: "! ", else: ""

    commands =
      pipeline.commands
      |> Enum.map(&format_command(&1, ctx))
      |> Enum.join(" | ")

    prefix <> commands
  end

  # Commands
  defp format_command(%AST.SimpleCommand{} = cmd, ctx) do
    parts = []

    # Assignments first
    parts =
      if cmd.assignments != [] do
        assigns = Enum.map(cmd.assignments, &format_assignment/1)
        parts ++ assigns
      else
        parts
      end

    # Command name and args
    parts =
      if cmd.name do
        name = format_word(cmd.name)
        args = Enum.map(cmd.args, &format_word/1)
        parts ++ [name | args]
      else
        parts
      end

    # Redirections
    parts =
      if cmd.redirections != [] do
        redirs = Enum.map(cmd.redirections, &format_redirection(&1, ctx))
        parts ++ redirs
      else
        parts
      end

    Enum.join(parts, " ")
  end

  defp format_command(%AST.If{} = node, ctx) do
    format_if(node, ctx)
  end

  defp format_command(%AST.For{} = node, ctx) do
    format_for(node, ctx)
  end

  defp format_command(%AST.CStyleFor{} = node, ctx) do
    format_c_style_for(node, ctx)
  end

  defp format_command(%AST.While{} = node, ctx) do
    format_while(node, ctx)
  end

  defp format_command(%AST.Until{} = node, ctx) do
    format_until(node, ctx)
  end

  defp format_command(%AST.Case{} = node, ctx) do
    format_case(node, ctx)
  end

  defp format_command(%AST.Subshell{} = node, ctx) do
    format_subshell(node, ctx)
  end

  defp format_command(%AST.Group{} = node, ctx) do
    format_group(node, ctx)
  end

  defp format_command(%AST.FunctionDef{} = node, ctx) do
    format_function_def(node, ctx)
  end

  defp format_command(%AST.ArithmeticCommand{} = node, _ctx) do
    "(( " <> format_arith_expr(node.expression) <> " ))"
  end

  defp format_command(%AST.ConditionalCommand{} = node, _ctx) do
    "[[ " <> format_conditional_expr(node.expression) <> " ]]"
  end

  # If statement
  defp format_if(%AST.If{clauses: clauses, else_body: else_body, redirections: redirs}, ctx) do
    inner_ctx = %{ctx | level: ctx.level + 1}
    indent = String.duplicate(ctx.indent, ctx.level)
    inner_indent = String.duplicate(ctx.indent, ctx.level + 1)

    formatted_clauses =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        keyword = if idx == 0, do: "if", else: "elif"
        condition = format_statements_inline(clause.condition, ctx)
        body = format_body(clause.body, inner_ctx, inner_indent)
        "#{keyword} #{condition}; then\n#{body}"
      end)
      |> Enum.join("\n#{indent}")

    formatted_else =
      if else_body do
        body = format_body(else_body, inner_ctx, inner_indent)
        "\n#{indent}else\n#{body}"
      else
        ""
      end

    result = "#{formatted_clauses}#{formatted_else}\n#{indent}fi"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # For loop
  defp format_for(%AST.For{variable: var, words: words, body: body, redirections: redirs}, ctx) do
    inner_ctx = %{ctx | level: ctx.level + 1}
    indent = String.duplicate(ctx.indent, ctx.level)
    inner_indent = String.duplicate(ctx.indent, ctx.level + 1)

    words_str =
      if words do
        " in " <> (words |> Enum.map(&format_word/1) |> Enum.join(" "))
      else
        ""
      end

    body_str = format_body(body, inner_ctx, inner_indent)

    result = "for #{var}#{words_str}; do\n#{body_str}\n#{indent}done"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # C-style for loop
  defp format_c_style_for(
         %AST.CStyleFor{
           init: init,
           condition: cond,
           update: update,
           body: body,
           redirections: redirs
         },
         ctx
       ) do
    inner_ctx = %{ctx | level: ctx.level + 1}
    indent = String.duplicate(ctx.indent, ctx.level)
    inner_indent = String.duplicate(ctx.indent, ctx.level + 1)

    init_str = if init, do: format_arith_expr(init), else: ""
    cond_str = if cond, do: format_arith_expr(cond), else: ""
    update_str = if update, do: format_arith_expr(update), else: ""

    body_str = format_body(body, inner_ctx, inner_indent)

    result = "for ((#{init_str}; #{cond_str}; #{update_str})); do\n#{body_str}\n#{indent}done"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # While loop
  defp format_while(%AST.While{condition: condition, body: body, redirections: redirs}, ctx) do
    inner_ctx = %{ctx | level: ctx.level + 1}
    indent = String.duplicate(ctx.indent, ctx.level)
    inner_indent = String.duplicate(ctx.indent, ctx.level + 1)

    cond_str = format_statements_inline(condition, ctx)
    body_str = format_body(body, inner_ctx, inner_indent)

    result = "while #{cond_str}; do\n#{body_str}\n#{indent}done"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # Until loop
  defp format_until(%AST.Until{condition: condition, body: body, redirections: redirs}, ctx) do
    inner_ctx = %{ctx | level: ctx.level + 1}
    indent = String.duplicate(ctx.indent, ctx.level)
    inner_indent = String.duplicate(ctx.indent, ctx.level + 1)

    cond_str = format_statements_inline(condition, ctx)
    body_str = format_body(body, inner_ctx, inner_indent)

    result = "until #{cond_str}; do\n#{body_str}\n#{indent}done"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # Case statement
  defp format_case(%AST.Case{word: word, items: items, redirections: redirs}, ctx) do
    inner_ctx = %{ctx | level: ctx.level + 1}
    indent = String.duplicate(ctx.indent, ctx.level)
    inner_indent = String.duplicate(ctx.indent, ctx.level + 1)
    body_indent = String.duplicate(ctx.indent, ctx.level + 2)

    formatted_items =
      items
      |> Enum.map(fn item ->
        patterns = item.patterns |> Enum.map(&format_word/1) |> Enum.join(" | ")
        body = format_body(item.body, %{inner_ctx | level: ctx.level + 2}, body_indent)
        terminator = format_case_terminator(item.terminator)
        "#{inner_indent}#{patterns})\n#{body}\n#{inner_indent}#{terminator}"
      end)
      |> Enum.join("\n")

    result = "case #{format_word(word)} in\n#{formatted_items}\n#{indent}esac"
    result <> format_redirections_suffix(redirs, ctx)
  end

  defp format_case_terminator(:dsemi), do: ";;"
  defp format_case_terminator(:semi_and), do: ";&"
  defp format_case_terminator(:semi_semi_and), do: ";;&"

  # Subshell
  defp format_subshell(%AST.Subshell{body: body, redirections: redirs}, ctx) do
    body_str = format_statements_inline(body, ctx)
    result = "( #{body_str} )"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # Group
  defp format_group(%AST.Group{body: body, redirections: redirs}, ctx) do
    body_str = format_statements_inline(body, ctx)
    result = "{ #{body_str}; }"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # Function definition
  defp format_function_def(%AST.FunctionDef{name: name, body: body, redirections: redirs}, ctx) do
    body_str = format_command(body, ctx)
    result = "#{name}() #{body_str}"
    result <> format_redirections_suffix(redirs, ctx)
  end

  # Format body statements with indentation
  defp format_body(statements, ctx, indent) do
    statements
    |> Enum.map(fn stmt ->
      indent <> format_statement(stmt, ctx)
    end)
    |> Enum.join("\n")
  end

  # Format statements inline (for conditions, etc.)
  defp format_statements_inline(statements, ctx) do
    statements
    |> Enum.map(&format_statement(&1, ctx))
    |> Enum.join("; ")
  end

  # Assignment
  defp format_assignment(%AST.Assignment{name: name, value: value, append: append, array: array}) do
    op = if append, do: "+=", else: "="

    cond do
      array != nil ->
        array_str = array |> Enum.map(&format_word/1) |> Enum.join(" ")
        "#{name}#{op}(#{array_str})"

      value != nil ->
        "#{name}#{op}#{format_word(value)}"

      true ->
        "#{name}#{op}"
    end
  end

  # Word
  defp format_word(%AST.Word{parts: parts}) do
    parts
    |> Enum.map(&format_word_part/1)
    |> Enum.join()
  end

  # Word parts
  defp format_word_part(%AST.Literal{value: value}) do
    escape_literal(value)
  end

  defp format_word_part(%AST.SingleQuoted{value: value}) do
    "'" <> value <> "'"
  end

  defp format_word_part(%AST.DoubleQuoted{parts: parts}) do
    inner = parts |> Enum.map(&format_double_quoted_part/1) |> Enum.join()
    "\"" <> inner <> "\""
  end

  defp format_word_part(%AST.Escaped{value: value}) do
    "\\" <> value
  end

  defp format_word_part(%AST.ParameterExpansion{parameter: param, operation: nil}) do
    if simple_var_name?(param) do
      "$#{param}"
    else
      "${#{param}}"
    end
  end

  defp format_word_part(%AST.ParameterExpansion{parameter: param, operation: %AST.Length{}}) do
    "${##{param}}"
  end

  defp format_word_part(%AST.ParameterExpansion{parameter: param, operation: %AST.Indirection{}}) do
    "${!#{param}}"
  end

  defp format_word_part(%AST.ParameterExpansion{parameter: param, operation: op}) do
    "${#{param}#{format_parameter_operation(op)}}"
  end

  defp format_word_part(%AST.CommandSubstitution{body: body, legacy: legacy}) do
    inner = format(body)

    if legacy do
      "`#{inner}`"
    else
      "$(#{inner})"
    end
  end

  defp format_word_part(%AST.ArithmeticExpansion{expression: expr}) do
    "$(( #{format_arith_expr(expr)} ))"
  end

  defp format_word_part(%AST.ProcessSubstitution{body: body, direction: dir}) do
    inner = format(body)

    case dir do
      :input -> "<(#{inner})"
      :output -> ">(#{inner})"
    end
  end

  defp format_word_part(%AST.BraceExpansion{items: items}) do
    inner =
      items
      |> Enum.map(&format_brace_item/1)
      |> Enum.join(",")

    "{#{inner}}"
  end

  defp format_word_part(%AST.TildeExpansion{user: nil}), do: "~"
  defp format_word_part(%AST.TildeExpansion{user: user}), do: "~#{user}"

  defp format_word_part(%AST.Glob{pattern: pattern}), do: pattern

  # Double-quoted parts (less escaping needed)
  defp format_double_quoted_part(%AST.Literal{value: value}) do
    escape_in_double_quotes(value)
  end

  defp format_double_quoted_part(%AST.Escaped{value: value}) do
    "\\" <> value
  end

  defp format_double_quoted_part(other), do: format_word_part(other)

  # Brace expansion items
  defp format_brace_item({:word, word}), do: format_word(word)

  defp format_brace_item({:range, start_val, end_val, nil}) do
    "#{start_val}..#{end_val}"
  end

  defp format_brace_item({:range, start_val, end_val, step}) do
    "#{start_val}..#{end_val}..#{step}"
  end

  # Parameter operations
  defp format_parameter_operation(%AST.DefaultValue{word: word, check_empty: check}) do
    op = if check, do: ":-", else: "-"
    op <> format_word(word)
  end

  defp format_parameter_operation(%AST.AssignDefault{word: word, check_empty: check}) do
    op = if check, do: ":=", else: "="
    op <> format_word(word)
  end

  defp format_parameter_operation(%AST.ErrorIfUnset{word: word, check_empty: check}) do
    op = if check, do: ":?", else: "?"
    if word, do: op <> format_word(word), else: op
  end

  defp format_parameter_operation(%AST.UseAlternative{word: word, check_empty: check}) do
    op = if check, do: ":+", else: "+"
    op <> format_word(word)
  end

  defp format_parameter_operation(%AST.Length{}), do: ""

  defp format_parameter_operation(%AST.Substring{offset: offset, length: nil}) do
    ":#{format_arith_expr(offset)}"
  end

  defp format_parameter_operation(%AST.Substring{offset: offset, length: length}) do
    ":#{format_arith_expr(offset)}:#{format_arith_expr(length)}"
  end

  defp format_parameter_operation(%AST.PatternRemoval{
         pattern: pattern,
         side: side,
         greedy: greedy
       }) do
    op =
      case {side, greedy} do
        {:prefix, false} -> "#"
        {:prefix, true} -> "##"
        {:suffix, false} -> "%"
        {:suffix, true} -> "%%"
      end

    op <> format_word(pattern)
  end

  defp format_parameter_operation(%AST.PatternReplacement{
         pattern: pattern,
         replacement: replacement,
         all: all,
         anchor: anchor
       }) do
    op = if all, do: "//", else: "/"

    anchor_prefix =
      case anchor do
        :start -> "#"
        :end -> "%"
        nil -> ""
      end

    repl = if replacement, do: "/" <> format_word(replacement), else: ""
    op <> anchor_prefix <> format_word(pattern) <> repl
  end

  defp format_parameter_operation(%AST.CaseModification{
         direction: dir,
         all: all,
         pattern: pattern
       }) do
    op =
      case {dir, all} do
        {:upper, false} -> "^"
        {:upper, true} -> "^^"
        {:lower, false} -> ","
        {:lower, true} -> ",,"
      end

    if pattern, do: op <> format_word(pattern), else: op
  end

  defp format_parameter_operation(%AST.Indirection{}), do: "!"

  # Redirections
  defp format_redirection(%AST.Redirection{fd: fd, operator: op, target: target}, ctx) do
    fd_str = if fd, do: Integer.to_string(fd), else: ""
    op_str = format_redir_operator(op)

    target_str =
      case target do
        %AST.HereDoc{} = heredoc -> format_heredoc(heredoc, ctx)
        word -> format_word(word)
      end

    "#{fd_str}#{op_str}#{target_str}"
  end

  defp format_redir_operator(:<), do: "<"
  defp format_redir_operator(:>), do: ">"
  defp format_redir_operator(:">>"), do: ">>"
  defp format_redir_operator(:">>&"), do: ">&"
  defp format_redir_operator(:">&"), do: ">&"
  defp format_redir_operator(:"<&"), do: "<&"
  defp format_redir_operator(:<>), do: "<>"
  defp format_redir_operator(:">|"), do: ">|"
  defp format_redir_operator(:"&>"), do: "&>"
  defp format_redir_operator(:"&>>"), do: "&>>"
  defp format_redir_operator(:<<<), do: "<<<"
  defp format_redir_operator(:"<<"), do: "<<"
  defp format_redir_operator(:"<<-"), do: "<<-"

  defp format_heredoc(
         %AST.HereDoc{delimiter: delim, content: content, strip_tabs: strip, quoted: quoted},
         _ctx
       ) do
    op = if strip, do: "-", else: ""
    delim_str = if quoted, do: "'#{delim}'", else: delim
    content_str = format_word(content)
    "#{op}#{delim_str}\n#{content_str}\n#{delim}"
  end

  defp format_redirections_suffix([], _ctx), do: ""

  defp format_redirections_suffix(redirs, ctx) do
    " " <> (redirs |> Enum.map(&format_redirection(&1, ctx)) |> Enum.join(" "))
  end

  # Arithmetic expressions
  defp format_arith_expr(%AST.ArithmeticExpression{expression: expr}) do
    format_arith_expr(expr)
  end

  defp format_arith_expr(%AST.ArithNumber{value: n}), do: Integer.to_string(n)

  defp format_arith_expr(%AST.ArithVariable{name: name}), do: name

  defp format_arith_expr(%AST.ArithBinary{operator: op, left: left, right: right}) do
    "#{format_arith_expr(left)} #{format_arith_op(op)} #{format_arith_expr(right)}"
  end

  defp format_arith_expr(%AST.ArithUnary{operator: op, operand: operand, prefix: true}) do
    "#{format_arith_op(op)}#{format_arith_expr(operand)}"
  end

  defp format_arith_expr(%AST.ArithUnary{operator: op, operand: operand, prefix: false}) do
    "#{format_arith_expr(operand)}#{format_arith_op(op)}"
  end

  defp format_arith_expr(%AST.ArithTernary{
         condition: cond,
         consequent: then_expr,
         alternate: else_expr
       }) do
    "#{format_arith_expr(cond)} ? #{format_arith_expr(then_expr)} : #{format_arith_expr(else_expr)}"
  end

  defp format_arith_expr(%AST.ArithAssignment{
         operator: op,
         variable: var,
         subscript: sub,
         value: val
       }) do
    subscript_str = if sub, do: "[#{format_arith_expr(sub)}]", else: ""
    "#{var}#{subscript_str} #{format_arith_op(op)} #{format_arith_expr(val)}"
  end

  defp format_arith_expr(%AST.ArithGroup{expression: expr}) do
    "(#{format_arith_expr(expr)})"
  end

  defp format_arith_expr(%AST.ArithArrayElement{array: arr, index: idx, string_key: key}) do
    subscript =
      cond do
        key -> "\"#{key}\""
        idx -> format_arith_expr(idx)
        true -> ""
      end

    "#{arr}[#{subscript}]"
  end

  # Support both atom and string operators (parser may use either)
  defp format_arith_op(op) when is_binary(op), do: op
  defp format_arith_op(op) when is_atom(op), do: Atom.to_string(op)

  # Conditional expressions
  defp format_conditional_expr(%AST.CondBinary{operator: op, left: left, right: right}) do
    "#{format_word(left)} #{format_cond_op(op)} #{format_word(right)}"
  end

  defp format_conditional_expr(%AST.CondUnary{operator: op, operand: operand}) do
    "#{format_cond_op(op)} #{format_word(operand)}"
  end

  defp format_conditional_expr(%AST.CondNot{operand: operand}) do
    "! #{format_conditional_expr(operand)}"
  end

  defp format_conditional_expr(%AST.CondAnd{left: left, right: right}) do
    "#{format_conditional_expr(left)} && #{format_conditional_expr(right)}"
  end

  defp format_conditional_expr(%AST.CondOr{left: left, right: right}) do
    "#{format_conditional_expr(left)} || #{format_conditional_expr(right)}"
  end

  defp format_conditional_expr(%AST.CondGroup{expression: expr}) do
    "( #{format_conditional_expr(expr)} )"
  end

  defp format_conditional_expr(%AST.CondWord{word: word}) do
    format_word(word)
  end

  defp format_cond_op(:=), do: "="
  defp format_cond_op(:==), do: "=="
  defp format_cond_op(:!=), do: "!="
  defp format_cond_op(:=~), do: "=~"
  defp format_cond_op(:<), do: "<"
  defp format_cond_op(:>), do: ">"
  defp format_cond_op(:"-eq"), do: "-eq"
  defp format_cond_op(:"-ne"), do: "-ne"
  defp format_cond_op(:"-lt"), do: "-lt"
  defp format_cond_op(:"-le"), do: "-le"
  defp format_cond_op(:"-gt"), do: "-gt"
  defp format_cond_op(:"-ge"), do: "-ge"
  defp format_cond_op(:"-nt"), do: "-nt"
  defp format_cond_op(:"-ot"), do: "-ot"
  defp format_cond_op(:"-ef"), do: "-ef"
  # Unary operators
  defp format_cond_op(:"-a"), do: "-a"
  defp format_cond_op(:"-b"), do: "-b"
  defp format_cond_op(:"-c"), do: "-c"
  defp format_cond_op(:"-d"), do: "-d"
  defp format_cond_op(:"-e"), do: "-e"
  defp format_cond_op(:"-f"), do: "-f"
  defp format_cond_op(:"-g"), do: "-g"
  defp format_cond_op(:"-h"), do: "-h"
  defp format_cond_op(:"-k"), do: "-k"
  defp format_cond_op(:"-p"), do: "-p"
  defp format_cond_op(:"-r"), do: "-r"
  defp format_cond_op(:"-s"), do: "-s"
  defp format_cond_op(:"-t"), do: "-t"
  defp format_cond_op(:"-u"), do: "-u"
  defp format_cond_op(:"-w"), do: "-w"
  defp format_cond_op(:"-x"), do: "-x"
  defp format_cond_op(:"-G"), do: "-G"
  defp format_cond_op(:"-L"), do: "-L"
  defp format_cond_op(:"-N"), do: "-N"
  defp format_cond_op(:"-O"), do: "-O"
  defp format_cond_op(:"-S"), do: "-S"
  defp format_cond_op(:"-z"), do: "-z"
  defp format_cond_op(:"-n"), do: "-n"
  defp format_cond_op(:"-o"), do: "-o"
  defp format_cond_op(:"-v"), do: "-v"
  defp format_cond_op(:"-R"), do: "-R"

  # Helper: check if parameter is a simple variable name (no special chars)
  defp simple_var_name?(name) do
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name) or
      Regex.match?(~r/^[0-9]+$/, name) or
      name in ["?", "$", "!", "#", "*", "@", "-", "0"]
  end

  # Helper: escape characters that need escaping outside quotes
  defp escape_literal(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(" ", "\\ ")
    |> String.replace("\t", "\\\t")
    |> String.replace("\n", "\\\n")
    |> String.replace("\"", "\\\"")
    |> String.replace("'", "\\'")
    |> String.replace("$", "\\$")
    |> String.replace("`", "\\`")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
    |> String.replace(";", "\\;")
    |> String.replace("&", "\\&")
    |> String.replace("|", "\\|")
    |> String.replace("<", "\\<")
    |> String.replace(">", "\\>")
  end

  # Helper: escape characters inside double quotes
  defp escape_in_double_quotes(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("$", "\\$")
    |> String.replace("`", "\\`")
  end
end
