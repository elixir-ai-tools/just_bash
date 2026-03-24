defmodule JustBash.Commands.Eval do
  @moduledoc """
  The `eval` builtin command - concatenate arguments and execute the result.

  `eval` joins all its arguments with spaces and executes the resulting string
  as a shell command in the current shell environment. Variable assignments,
  function definitions, and other side effects persist.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Interpreter.Executor
  alias JustBash.Parser
  alias JustBash.Security.Policy

  @impl true
  def names, do: ["eval"]

  @impl true
  def execute(bash, [], _stdin) do
    {%{stdout: "", stderr: "", exit_code: 0}, bash}
  end

  def execute(bash, args, _stdin) do
    script = Enum.join(args, " ")

    parser_opts = [
      max_input_bytes: Policy.get(bash, :max_input_bytes),
      max_tokens: Policy.get(bash, :max_tokens)
    ]

    try do
      case Parser.parse(script, parser_opts) do
        {:ok, ast} ->
          Executor.execute_script(bash, ast)

        {:error, error} ->
          {%{
             stdout: "",
             stderr: "bash: eval: syntax error: #{error.message}\n",
             exit_code: 2
           }, bash}
      end
    rescue
      e in RuntimeError ->
        {%{
           stdout: "",
           stderr: "bash: eval: syntax error: #{Exception.message(e)}\n",
           exit_code: 2
         }, bash}
    end
  end
end
