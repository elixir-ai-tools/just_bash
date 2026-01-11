defmodule JustBash.Interpreter.Expansion do
  @moduledoc """
  Handles shell expansion: variables, command substitution, arithmetic.
  """

  alias JustBash.Arithmetic
  alias JustBash.AST
  alias JustBash.Interpreter.Executor

  @doc """
  Expand word parts into a string, handling all substitution types.
  """
  @spec expand_word_parts(JustBash.t(), [AST.word_part()]) :: String.t()
  def expand_word_parts(bash, parts) do
    Enum.map_join(parts, "", &expand_part(bash, &1))
  end

  defp expand_part(_bash, part) when is_binary(part), do: part

  defp expand_part(_bash, %AST.Literal{value: value}), do: value

  defp expand_part(_bash, %AST.SingleQuoted{value: value}), do: value

  defp expand_part(_bash, %AST.Escaped{value: value}), do: value

  defp expand_part(bash, %AST.DoubleQuoted{parts: parts}) do
    expand_word_parts(bash, parts)
  end

  defp expand_part(bash, %AST.ParameterExpansion{} = param) do
    expand_parameter(bash, param)
  end

  defp expand_part(bash, %AST.CommandSubstitution{body: body}) do
    execute_command_substitution(bash, body)
  end

  defp expand_part(bash, %AST.ArithmeticExpression{} = expr) do
    execute_arithmetic_expansion(bash, expr)
  end

  defp expand_part(bash, %AST.ArithmeticExpansion{expression: expr}) do
    execute_arithmetic_expansion(bash, expr)
  end

  defp expand_part(bash, %{parts: parts}) do
    expand_word_parts(bash, parts)
  end

  defp expand_part(_bash, _), do: ""

  defp execute_arithmetic_expansion(bash, %AST.ArithmeticExpression{expression: inner_expr}) do
    {value, _env} = Arithmetic.evaluate(inner_expr, bash.env)
    to_string(value)
  end

  defp execute_arithmetic_expansion(bash, expr) do
    {value, _env} = Arithmetic.evaluate(expr, bash.env)
    to_string(value)
  end

  defp execute_command_substitution(bash, %AST.Script{} = script) do
    {result, _bash} = Executor.execute_script(bash, script)
    String.trim_trailing(result.stdout, "\n")
  end

  @doc """
  Expand a parameter with optional operations.
  """
  @spec expand_parameter(JustBash.t(), AST.ParameterExpansion.t()) :: String.t()
  def expand_parameter(bash, %AST.ParameterExpansion{parameter: name, operation: nil}) do
    Map.get(bash.env, name, "")
  end

  def expand_parameter(bash, %AST.ParameterExpansion{parameter: name, operation: operation}) do
    value = Map.get(bash.env, name)
    expand_with_operation(bash, value, operation)
  end

  defp expand_with_operation(bash, value, %AST.DefaultValue{word: word, check_empty: check_empty}) do
    default_val = if word, do: expand_word_parts(bash, word.parts), else: ""

    should_use_default =
      if check_empty do
        value == nil or value == ""
      else
        value == nil
      end

    if should_use_default, do: default_val, else: value || ""
  end

  defp expand_with_operation(bash, value, %AST.UseAlternative{
         word: word,
         check_empty: check_empty
       }) do
    alt_val = if word, do: expand_word_parts(bash, word.parts), else: ""

    should_use_alt =
      if check_empty do
        value != nil and value != ""
      else
        value != nil
      end

    if should_use_alt, do: alt_val, else: ""
  end

  defp expand_with_operation(_bash, value, %AST.Length{}) do
    String.length(value || "") |> to_string()
  end

  defp expand_with_operation(_bash, value, _operation) do
    value || ""
  end

  @doc """
  Expand redirection target.
  """
  @spec expand_redirect_target(JustBash.t(), AST.Word.t() | String.t() | any()) :: String.t()
  def expand_redirect_target(bash, %AST.Word{parts: parts}) do
    expand_word_parts(bash, parts)
  end

  def expand_redirect_target(_bash, target) when is_binary(target), do: target
  def expand_redirect_target(_bash, _), do: ""
end
