defmodule JustBash.Arithmetic do
  @moduledoc """
  Arithmetic expression parsing and evaluation for bash.

  Supports:
  - Basic operators: +, -, *, /, %
  - Comparison operators: <, <=, >, >=, ==, !=
  - Bitwise operators: &, |, ^, ~, <<, >>
  - Logical operators: &&, ||, !
  - Assignment operators: =, +=, -=, etc.
  - Pre/post increment/decrement: ++, --
  - Ternary operator: ? :
  - Parentheses for grouping
  - Variable references

  Delegates to:
  - `JustBash.Arithmetic.Parser` for parsing
  - `JustBash.Arithmetic.Evaluator` for evaluation
  """

  alias JustBash.Arithmetic.Evaluator
  alias JustBash.Arithmetic.Parser

  @doc """
  Parse an arithmetic expression string into an AST.
  """
  defdelegate parse(expr_str), to: Parser

  @doc """
  Evaluate an arithmetic AST in the given environment.
  Returns {result, updated_env}.
  """
  defdelegate evaluate(ast, env), to: Evaluator
end
