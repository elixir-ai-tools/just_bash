defmodule JustBash.AST do
  @moduledoc """
  Abstract Syntax Tree (AST) Types for Bash

  This module defines the complete AST structure for bash scripts.
  The design follows the actual bash grammar while being Elixir-idiomatic.

  Architecture:
    Input -> Lexer -> Parser -> AST -> Interpreter -> Output
  """

  defmodule Script do
    @moduledoc "Root node: a complete script"
    defstruct statements: []

    @type t :: %__MODULE__{
            statements: [JustBash.AST.Statement.t()]
          }
  end

  defmodule Statement do
    @moduledoc "A statement is a list of pipelines connected by && or ||"
    defstruct pipelines: [], operators: [], background: false

    @type operator :: :and | :or | :semi
    @type t :: %__MODULE__{
            pipelines: [JustBash.AST.Pipeline.t()],
            operators: [operator()],
            background: boolean()
          }
  end

  defmodule Pipeline do
    @moduledoc "A pipeline: cmd1 | cmd2 | cmd3"
    defstruct commands: [], negated: false

    @type t :: %__MODULE__{
            commands: [JustBash.AST.command()],
            negated: boolean()
          }
  end

  defmodule SimpleCommand do
    @moduledoc "Simple command: name args... with optional redirections"
    defstruct assignments: [], name: nil, args: [], redirections: [], line: nil

    @type t :: %__MODULE__{
            assignments: [JustBash.AST.Assignment.t()],
            name: JustBash.AST.Word.t() | nil,
            args: [JustBash.AST.Word.t()],
            redirections: [JustBash.AST.Redirection.t()],
            line: non_neg_integer() | nil
          }
  end

  defmodule If do
    @moduledoc "if statement"
    defstruct clauses: [], else_body: nil, redirections: []

    @type t :: %__MODULE__{
            clauses: [JustBash.AST.IfClause.t()],
            else_body: [JustBash.AST.Statement.t()] | nil,
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule IfClause do
    @moduledoc "Single if/elif clause with condition and body"
    defstruct condition: [], body: []

    @type t :: %__MODULE__{
            condition: [JustBash.AST.Statement.t()],
            body: [JustBash.AST.Statement.t()]
          }
  end

  defmodule For do
    @moduledoc "for loop: for VAR in WORDS; do ...; done"
    defstruct variable: "", words: nil, body: [], redirections: []

    @type t :: %__MODULE__{
            variable: String.t(),
            words: [JustBash.AST.Word.t()] | nil,
            body: [JustBash.AST.Statement.t()],
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule CStyleFor do
    @moduledoc "C-style for loop: for ((init; cond; step)); do ...; done"
    defstruct init: nil, condition: nil, update: nil, body: [], redirections: []

    @type t :: %__MODULE__{
            init: JustBash.AST.ArithmeticExpression.t() | nil,
            condition: JustBash.AST.ArithmeticExpression.t() | nil,
            update: JustBash.AST.ArithmeticExpression.t() | nil,
            body: [JustBash.AST.Statement.t()],
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule While do
    @moduledoc "while loop"
    defstruct condition: [], body: [], redirections: []

    @type t :: %__MODULE__{
            condition: [JustBash.AST.Statement.t()],
            body: [JustBash.AST.Statement.t()],
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule Until do
    @moduledoc "until loop"
    defstruct condition: [], body: [], redirections: []

    @type t :: %__MODULE__{
            condition: [JustBash.AST.Statement.t()],
            body: [JustBash.AST.Statement.t()],
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule Case do
    @moduledoc "case statement"
    defstruct word: nil, items: [], redirections: []

    @type t :: %__MODULE__{
            word: JustBash.AST.Word.t(),
            items: [JustBash.AST.CaseItem.t()],
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule CaseItem do
    @moduledoc "Single case item with patterns and body"
    defstruct patterns: [], body: [], terminator: :dsemi

    @type terminator :: :dsemi | :semi_and | :semi_semi_and
    @type t :: %__MODULE__{
            patterns: [JustBash.AST.Word.t()],
            body: [JustBash.AST.Statement.t()],
            terminator: terminator()
          }
  end

  defmodule Subshell do
    @moduledoc "Subshell: ( ... )"
    defstruct body: [], redirections: []

    @type t :: %__MODULE__{
            body: [JustBash.AST.Statement.t()],
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule Group do
    @moduledoc "Command group: { ...; }"
    defstruct body: [], redirections: []

    @type t :: %__MODULE__{
            body: [JustBash.AST.Statement.t()],
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule ArithmeticCommand do
    @moduledoc "Arithmetic command: (( expr ))"
    defstruct expression: nil, redirections: []

    @type t :: %__MODULE__{
            expression: JustBash.AST.ArithmeticExpression.t(),
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule ConditionalCommand do
    @moduledoc "Conditional command: [[ expr ]]"
    defstruct expression: nil, redirections: []

    @type t :: %__MODULE__{
            expression: JustBash.AST.conditional_expression(),
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule FunctionDef do
    @moduledoc "Function definition"
    defstruct name: "", body: nil, redirections: []

    @type t :: %__MODULE__{
            name: String.t(),
            body: JustBash.AST.compound_command(),
            redirections: [JustBash.AST.Redirection.t()]
          }
  end

  defmodule Assignment do
    @moduledoc "Variable assignment: VAR=value or VAR+=value"
    defstruct name: "", value: nil, append: false, array: nil

    @type t :: %__MODULE__{
            name: String.t(),
            value: JustBash.AST.Word.t() | nil,
            append: boolean(),
            array: [JustBash.AST.Word.t()] | nil
          }
  end

  defmodule Redirection do
    @moduledoc "I/O redirection"
    defstruct fd: nil, operator: nil, target: nil

    @type operator ::
            :< | :> | :">>" | :">&" | :"<&" | :<> | :">|" | :"&>" | :"&>>" | :<<< | :"<<" | :"<<-"
    @type t :: %__MODULE__{
            fd: non_neg_integer() | nil,
            operator: operator(),
            target: JustBash.AST.Word.t() | JustBash.AST.HereDoc.t()
          }
  end

  defmodule HereDoc do
    @moduledoc "Here document"
    defstruct delimiter: "", content: nil, strip_tabs: false, quoted: false

    @type t :: %__MODULE__{
            delimiter: String.t(),
            content: JustBash.AST.Word.t(),
            strip_tabs: boolean(),
            quoted: boolean()
          }
  end

  defmodule Word do
    @moduledoc """
    A Word is a sequence of parts that form a single shell word.
    After expansion, it may produce zero, one, or multiple strings.
    """
    defstruct parts: []

    @type t :: %__MODULE__{
            parts: [JustBash.AST.word_part()]
          }
  end

  defmodule Literal do
    @moduledoc "Literal text (no special meaning)"
    defstruct value: ""

    @type t :: %__MODULE__{value: String.t()}
  end

  defmodule SingleQuoted do
    @moduledoc "Single-quoted string: 'literal'"
    defstruct value: ""

    @type t :: %__MODULE__{value: String.t()}
  end

  defmodule DoubleQuoted do
    @moduledoc "Double-quoted string: \"with $expansion\""
    defstruct parts: []

    @type t :: %__MODULE__{parts: [JustBash.AST.word_part()]}
  end

  defmodule Escaped do
    @moduledoc "Escaped character: \\x"
    defstruct value: ""

    @type t :: %__MODULE__{value: String.t()}
  end

  defmodule ParameterExpansion do
    @moduledoc "Parameter/variable expansion: $VAR or ${VAR...}"
    defstruct parameter: "", operation: nil

    @type t :: %__MODULE__{
            parameter: String.t(),
            operation: JustBash.AST.parameter_operation() | nil
          }
  end

  defmodule CommandSubstitution do
    @moduledoc "Command substitution: $(cmd) or `cmd`"
    defstruct body: nil, legacy: false

    @type t :: %__MODULE__{
            body: JustBash.AST.Script.t(),
            legacy: boolean()
          }
  end

  defmodule ArithmeticExpansion do
    @moduledoc "Arithmetic expansion: $((expr))"
    defstruct expression: nil

    @type t :: %__MODULE__{
            expression: JustBash.AST.ArithmeticExpression.t()
          }
  end

  defmodule ProcessSubstitution do
    @moduledoc "Process substitution: <(cmd) or >(cmd)"
    defstruct body: nil, direction: :input

    @type direction :: :input | :output
    @type t :: %__MODULE__{
            body: JustBash.AST.Script.t(),
            direction: direction()
          }
  end

  defmodule BraceExpansion do
    @moduledoc "Brace expansion: {a,b,c} or {1..10}"
    defstruct items: []

    @type t :: %__MODULE__{
            items: [JustBash.AST.brace_item()]
          }
  end

  defmodule TildeExpansion do
    @moduledoc "Tilde expansion: ~ or ~user"
    defstruct user: nil

    @type t :: %__MODULE__{user: String.t() | nil}
  end

  defmodule Glob do
    @moduledoc "Glob pattern part (expanded during pathname expansion)"
    defstruct pattern: ""

    @type t :: %__MODULE__{pattern: String.t()}
  end

  defmodule ArithmeticExpression do
    @moduledoc "Arithmetic expression (for $((...)) and ((...)))"
    defstruct expression: nil

    @type t :: %__MODULE__{
            expression: JustBash.AST.arith_expr()
          }
  end

  defmodule ArithNumber do
    @moduledoc "Arithmetic number literal"
    defstruct value: 0

    @type t :: %__MODULE__{value: integer()}
  end

  defmodule ArithVariable do
    @moduledoc "Arithmetic variable reference"
    defstruct name: ""

    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule ArithBinary do
    @moduledoc "Arithmetic binary operation"
    defstruct operator: nil, left: nil, right: nil

    @type operator ::
            :+
            | :-
            | :*
            | :/
            | :%
            | :**
            | :"<<"
            | :">>"
            | :<
            | :<=
            | :>
            | :>=
            | :==
            | :!=
            | :&
            | :|
            | :^
            | :&&
            | :||
            | :","
    @type t :: %__MODULE__{
            operator: operator(),
            left: JustBash.AST.arith_expr(),
            right: JustBash.AST.arith_expr()
          }
  end

  defmodule ArithUnary do
    @moduledoc "Arithmetic unary operation"
    defstruct operator: nil, operand: nil, prefix: true

    @type operator :: :- | :+ | :! | :"~" | :++ | :--
    @type t :: %__MODULE__{
            operator: operator(),
            operand: JustBash.AST.arith_expr(),
            prefix: boolean()
          }
  end

  defmodule ArithTernary do
    @moduledoc "Arithmetic ternary operation: cond ? then : else"
    defstruct condition: nil, consequent: nil, alternate: nil

    @type t :: %__MODULE__{
            condition: JustBash.AST.arith_expr(),
            consequent: JustBash.AST.arith_expr(),
            alternate: JustBash.AST.arith_expr()
          }
  end

  defmodule ArithAssignment do
    @moduledoc "Arithmetic assignment"
    defstruct operator: :=, variable: "", subscript: nil, string_key: nil, value: nil

    @type operator ::
            := | :"+=" | :"-=" | :"*=" | :"/=" | :"%=" | :"<<=" | :">>=" | :"&=" | :"|=" | :"^="
    @type t :: %__MODULE__{
            operator: operator(),
            variable: String.t(),
            subscript: JustBash.AST.arith_expr() | nil,
            string_key: String.t() | nil,
            value: JustBash.AST.arith_expr()
          }
  end

  defmodule ArithGroup do
    @moduledoc "Arithmetic grouped expression: (expr)"
    defstruct expression: nil

    @type t :: %__MODULE__{expression: JustBash.AST.arith_expr()}
  end

  defmodule ArithArrayElement do
    @moduledoc "Arithmetic array element access"
    defstruct array: "", index: nil, string_key: nil

    @type t :: %__MODULE__{
            array: String.t(),
            index: JustBash.AST.arith_expr() | nil,
            string_key: String.t() | nil
          }
  end

  defmodule CondBinary do
    @moduledoc "Conditional binary expression"
    defstruct operator: nil, left: nil, right: nil

    @type operator ::
            :=
            | :==
            | :!=
            | :=~
            | :<
            | :>
            | :"-eq"
            | :"-ne"
            | :"-lt"
            | :"-le"
            | :"-gt"
            | :"-ge"
            | :"-nt"
            | :"-ot"
            | :"-ef"
    @type t :: %__MODULE__{
            operator: operator(),
            left: JustBash.AST.Word.t(),
            right: JustBash.AST.Word.t()
          }
  end

  defmodule CondUnary do
    @moduledoc "Conditional unary expression"
    defstruct operator: nil, operand: nil

    @type operator ::
            :"-a"
            | :"-b"
            | :"-c"
            | :"-d"
            | :"-e"
            | :"-f"
            | :"-g"
            | :"-h"
            | :"-k"
            | :"-p"
            | :"-r"
            | :"-s"
            | :"-t"
            | :"-u"
            | :"-w"
            | :"-x"
            | :"-G"
            | :"-L"
            | :"-N"
            | :"-O"
            | :"-S"
            | :"-z"
            | :"-n"
            | :"-o"
            | :"-v"
            | :"-R"
    @type t :: %__MODULE__{
            operator: operator(),
            operand: JustBash.AST.Word.t()
          }
  end

  defmodule CondNot do
    @moduledoc "Conditional NOT expression"
    defstruct operand: nil

    @type t :: %__MODULE__{operand: JustBash.AST.conditional_expression()}
  end

  defmodule CondAnd do
    @moduledoc "Conditional AND expression"
    defstruct left: nil, right: nil

    @type t :: %__MODULE__{
            left: JustBash.AST.conditional_expression(),
            right: JustBash.AST.conditional_expression()
          }
  end

  defmodule CondOr do
    @moduledoc "Conditional OR expression"
    defstruct left: nil, right: nil

    @type t :: %__MODULE__{
            left: JustBash.AST.conditional_expression(),
            right: JustBash.AST.conditional_expression()
          }
  end

  defmodule CondGroup do
    @moduledoc "Conditional grouped expression"
    defstruct expression: nil

    @type t :: %__MODULE__{expression: JustBash.AST.conditional_expression()}
  end

  defmodule CondWord do
    @moduledoc "Conditional word (for simple string tests)"
    defstruct word: nil

    @type t :: %__MODULE__{word: JustBash.AST.Word.t()}
  end

  defmodule DefaultValue do
    @moduledoc "${VAR:-default} or ${VAR-default}"
    defstruct word: nil, check_empty: false

    @type t :: %__MODULE__{word: JustBash.AST.Word.t(), check_empty: boolean()}
  end

  defmodule AssignDefault do
    @moduledoc "${VAR:=default} or ${VAR=default}"
    defstruct word: nil, check_empty: false

    @type t :: %__MODULE__{word: JustBash.AST.Word.t(), check_empty: boolean()}
  end

  defmodule ErrorIfUnset do
    @moduledoc "${VAR:?error} or ${VAR?error}"
    defstruct word: nil, check_empty: false

    @type t :: %__MODULE__{word: JustBash.AST.Word.t() | nil, check_empty: boolean()}
  end

  defmodule UseAlternative do
    @moduledoc "${VAR:+alternative} or ${VAR+alternative}"
    defstruct word: nil, check_empty: false

    @type t :: %__MODULE__{word: JustBash.AST.Word.t(), check_empty: boolean()}
  end

  defmodule Length do
    @moduledoc "${#VAR}"
    defstruct []

    @type t :: %__MODULE__{}
  end

  defmodule Substring do
    @moduledoc "${VAR:offset} or ${VAR:offset:length}"
    defstruct offset: nil, length: nil

    @type t :: %__MODULE__{
            offset: JustBash.AST.ArithmeticExpression.t(),
            length: JustBash.AST.ArithmeticExpression.t() | nil
          }
  end

  defmodule PatternRemoval do
    @moduledoc "${VAR#pattern}, ${VAR##pattern}, ${VAR%pattern}, ${VAR%%pattern}"
    defstruct pattern: nil, side: :prefix, greedy: false

    @type side :: :prefix | :suffix
    @type t :: %__MODULE__{
            pattern: JustBash.AST.Word.t(),
            side: side(),
            greedy: boolean()
          }
  end

  defmodule PatternReplacement do
    @moduledoc "${VAR/pattern/replacement} or ${VAR//pattern/replacement}"
    defstruct pattern: nil, replacement: nil, all: false, anchor: nil

    @type anchor :: :start | :end | nil
    @type t :: %__MODULE__{
            pattern: JustBash.AST.Word.t(),
            replacement: JustBash.AST.Word.t() | nil,
            all: boolean(),
            anchor: anchor()
          }
  end

  defmodule CaseModification do
    @moduledoc "${VAR^}, ${VAR^^}, ${VAR,}, ${VAR,,}"
    defstruct direction: :upper, all: false, pattern: nil

    @type direction :: :upper | :lower
    @type t :: %__MODULE__{
            direction: direction(),
            all: boolean(),
            pattern: JustBash.AST.Word.t() | nil
          }
  end

  defmodule Indirection do
    @moduledoc "${!VAR} - indirect expansion"
    defstruct []

    @type t :: %__MODULE__{}
  end

  @type command ::
          SimpleCommand.t()
          | compound_command()
          | FunctionDef.t()

  @type compound_command ::
          If.t()
          | For.t()
          | CStyleFor.t()
          | While.t()
          | Until.t()
          | Case.t()
          | Subshell.t()
          | Group.t()
          | ArithmeticCommand.t()
          | ConditionalCommand.t()

  @type word_part ::
          Literal.t()
          | SingleQuoted.t()
          | DoubleQuoted.t()
          | Escaped.t()
          | ParameterExpansion.t()
          | CommandSubstitution.t()
          | ArithmeticExpansion.t()
          | ProcessSubstitution.t()
          | BraceExpansion.t()
          | TildeExpansion.t()
          | Glob.t()

  @type arith_expr ::
          ArithNumber.t()
          | ArithVariable.t()
          | ArithBinary.t()
          | ArithUnary.t()
          | ArithTernary.t()
          | ArithAssignment.t()
          | ArithGroup.t()
          | ArithArrayElement.t()

  @type conditional_expression ::
          CondBinary.t()
          | CondUnary.t()
          | CondNot.t()
          | CondAnd.t()
          | CondOr.t()
          | CondGroup.t()
          | CondWord.t()

  @type parameter_operation ::
          DefaultValue.t()
          | AssignDefault.t()
          | ErrorIfUnset.t()
          | UseAlternative.t()
          | Length.t()
          | Substring.t()
          | PatternRemoval.t()
          | PatternReplacement.t()
          | CaseModification.t()
          | Indirection.t()

  @type brace_item ::
          {:word, Word.t()}
          | {:range, start :: String.t() | integer(), end_val :: String.t() | integer(),
             step :: integer() | nil}

  def script(statements), do: %Script{statements: statements}

  def statement(pipelines, operators \\ [], background \\ false) do
    %Statement{pipelines: pipelines, operators: operators, background: background}
  end

  def pipeline(commands, negated \\ false) do
    %Pipeline{commands: commands, negated: negated}
  end

  def simple_command(name, args \\ [], assignments \\ [], redirections \\ [], line \\ nil) do
    %SimpleCommand{
      name: name,
      args: args,
      assignments: assignments,
      redirections: redirections,
      line: line
    }
  end

  def word(parts), do: %Word{parts: parts}
  def literal(value), do: %Literal{value: value}
  def single_quoted(value), do: %SingleQuoted{value: value}
  def double_quoted(parts), do: %DoubleQuoted{parts: parts}
  def escaped(value), do: %Escaped{value: value}

  def parameter_expansion(parameter, operation \\ nil) do
    %ParameterExpansion{parameter: parameter, operation: operation}
  end

  def command_substitution(body, legacy \\ false) do
    %CommandSubstitution{body: body, legacy: legacy}
  end

  def arithmetic_expansion(expression) do
    %ArithmeticExpansion{expression: expression}
  end

  def assignment(name, value, append \\ false, array \\ nil) do
    %Assignment{name: name, value: value, append: append, array: array}
  end

  def redirection(operator, target, fd \\ nil) do
    %Redirection{fd: fd, operator: operator, target: target}
  end

  def here_doc(delimiter, content, strip_tabs \\ false, quoted \\ false) do
    %HereDoc{delimiter: delimiter, content: content, strip_tabs: strip_tabs, quoted: quoted}
  end

  def if_node(clauses, else_body \\ nil, redirections \\ []) do
    %If{clauses: clauses, else_body: else_body, redirections: redirections}
  end

  def if_clause(condition, body), do: %IfClause{condition: condition, body: body}

  def for_node(variable, words, body, redirections \\ []) do
    %For{variable: variable, words: words, body: body, redirections: redirections}
  end

  def while_node(condition, body, redirections \\ []) do
    %While{condition: condition, body: body, redirections: redirections}
  end

  def until_node(condition, body, redirections \\ []) do
    %Until{condition: condition, body: body, redirections: redirections}
  end

  def case_node(word, items, redirections \\ []) do
    %Case{word: word, items: items, redirections: redirections}
  end

  def case_item(patterns, body, terminator \\ :dsemi) do
    %CaseItem{patterns: patterns, body: body, terminator: terminator}
  end

  def subshell(body, redirections \\ []) do
    %Subshell{body: body, redirections: redirections}
  end

  def group(body, redirections \\ []) do
    %Group{body: body, redirections: redirections}
  end

  def function_def(name, body, redirections \\ []) do
    %FunctionDef{name: name, body: body, redirections: redirections}
  end

  def conditional_command(expression, redirections \\ []) do
    %ConditionalCommand{expression: expression, redirections: redirections}
  end

  def arithmetic_command(expression, redirections \\ []) do
    %ArithmeticCommand{expression: expression, redirections: redirections}
  end
end
