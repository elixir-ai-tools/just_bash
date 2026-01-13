defmodule JustBash.Commands.Printenv do
  @moduledoc "The `printenv` command - print all or part of environment."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["printenv"]

  @impl true
  def execute(bash, args, _stdin) do
    vars = Enum.reject(args, &String.starts_with?(&1, "-"))
    execute_printenv(bash, vars)
  end

  defp execute_printenv(bash, []) do
    output = format_all_env(bash.env)
    {Command.ok(output), bash}
  end

  defp execute_printenv(bash, vars) do
    {lines, exit_code} = collect_var_values(bash.env, vars)
    output = format_lines(lines)
    {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
  end

  defp format_all_env(env) do
    env
    |> Enum.sort()
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
    |> append_newline()
  end

  defp collect_var_values(env, vars) do
    Enum.reduce(vars, {[], 0}, fn var, {acc_lines, acc_code} ->
      case Map.fetch(env, var) do
        {:ok, value} -> {acc_lines ++ [value], acc_code}
        :error -> {acc_lines, 1}
      end
    end)
  end

  defp format_lines(lines) do
    lines |> Enum.join("\n") |> append_newline()
  end

  defp append_newline(""), do: ""
  defp append_newline(s), do: s <> "\n"
end
