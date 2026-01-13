defmodule JustBash.Commands.Printenv do
  @moduledoc "The `printenv` command - print all or part of environment."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["printenv"]

  @impl true
  def execute(bash, args, _stdin) do
    vars = Enum.reject(args, &String.starts_with?(&1, "-"))

    if vars == [] do
      output =
        bash.env
        |> Enum.sort()
        |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
        |> then(fn s -> if s == "", do: "", else: s <> "\n" end)

      {Command.ok(output), bash}
    else
      {lines, exit_code} =
        Enum.reduce(vars, {[], 0}, fn var, {acc_lines, acc_code} ->
          case Map.fetch(bash.env, var) do
            {:ok, value} -> {acc_lines ++ [value], acc_code}
            :error -> {acc_lines, 1}
          end
        end)

      output =
        lines
        |> Enum.join("\n")
        |> then(fn s -> if s == "", do: "", else: s <> "\n" end)

      {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
    end
  end
end
