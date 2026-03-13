# scripts/extract_bash_cases.exs
#
# Extracts compare_bash() calls from test/bash_comparison/*_test.exs
# and writes JSON case files to test/fixtures/bash_cases/.
#
# Usage: mix run scripts/extract_bash_cases.exs
#
# Special cases (direct run_real_bash/run_just_bash, JustBash.new with files)
# are skipped — they need manual handling or remain in the original test files.

defmodule BashCaseExtractor do
  @test_dir "test/bash_comparison"
  @output_dir "test/fixtures/bash_cases"

  def run do
    File.mkdir_p!(@output_dir)

    Path.wildcard(Path.join(@test_dir, "*_test.exs"))
    |> Enum.sort()
    |> Enum.each(&process_file/1)
  end

  defp process_file(path) do
    suite = path |> Path.basename("_test.exs")
    content = File.read!(path)

    # Skip date_test — needs special handling for platform-specific commands
    if suite == "date" do
      IO.puts("SKIP: #{suite} (platform-specific date_cmd helper)")
      return_skip()
    else
      cases = extract_cases(content, path)

      if cases == [] do
        IO.puts("SKIP: #{suite} (no compare_bash calls found)")
      else
        json = %{suite: suite, cases: cases}
        output_path = Path.join(@output_dir, "#{suite}.json")
        File.write!(output_path, Jason.encode!(json, pretty: true) <> "\n")
        IO.puts("OK:   #{suite} — #{length(cases)} cases -> #{output_path}")
      end
    end
  end

  defp return_skip, do: :ok

  defp extract_cases(content, path) do
    {:ok, ast} = Code.string_to_quoted(content, file: path)
    walk_ast(ast, nil, []) |> Enum.reverse()
  end

  # Walk the AST looking for describe blocks and test blocks containing compare_bash
  defp walk_ast({:defmodule, _, [_alias, [do: body]]}, describe, acc) do
    walk_ast(body, describe, acc)
  end

  defp walk_ast({:describe, _, [label, [do: body]]}, _describe, acc) do
    walk_ast(body, label, acc)
  end

  defp walk_ast({:__block__, _, children}, describe, acc) do
    {acc, _skip} =
      Enum.reduce(children, {acc, false}, fn child, {acc, skip} ->
        case child do
          # @tag :skip — mark next test to skip
          {:@, _, [{:tag, _, [:skip]}]} ->
            {acc, true}

          # @tag skip: "reason"
          {:@, _, [{:tag, _, [[skip: _]]}]} ->
            {acc, true}

          {:test, _, _} when skip ->
            {acc, false}

          _ ->
            {walk_ast(child, describe, acc), false}
        end
      end)

    acc
  end

  defp walk_ast({:test, _, [name, [do: body]]}, describe, acc) do
    cases = extract_compare_bash_calls(body)

    cases
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {{script, opts}, idx}, acc ->
      base_name =
        if describe do
          "#{describe}: #{name}"
        else
          name
        end

      test_name =
        if length(cases) > 1 do
          "#{base_name} (#{idx + 1})"
        else
          base_name
        end

      case_entry = %{name: test_name, script: script}

      case_entry =
        if opts != %{} do
          Map.put(case_entry, :opts, opts)
        else
          case_entry
        end

      [case_entry | acc]
    end)
  end

  defp walk_ast(_, _describe, acc), do: acc

  # Extract compare_bash calls from a test body
  defp extract_compare_bash_calls(body) do
    extract_compare_bash_calls(body, %{})
  end

  defp extract_compare_bash_calls({:__block__, _, statements}, bindings) do
    {results, _bindings} =
      Enum.reduce(statements, {[], bindings}, fn stmt, {acc, bindings} ->
        case stmt do
          # Variable assignment: cmd = "..."
          {:=, _, [{var_name, _, nil}, value]} when is_atom(var_name) ->
            case eval_script(value) do
              {:ok, s} -> {acc, Map.put(bindings, var_name, s)}
              :error -> {acc, bindings}
            end

          # compare_bash(expr)
          {:compare_bash, _, [script]} ->
            case resolve_script(script, bindings) do
              {:ok, s} -> {[{s, %{}} | acc], bindings}
              :error -> {acc, bindings}
            end

          # compare_bash(expr, opts)
          {:compare_bash, _, [script, opts]} ->
            case resolve_script(script, bindings) do
              {:ok, s} -> {[{s, eval_opts(opts)} | acc], bindings}
              :error -> {acc, bindings}
            end

          _ ->
            {acc, bindings}
        end
      end)

    Enum.reverse(results)
  end

  defp extract_compare_bash_calls({:compare_bash, _, [script]}, bindings) do
    case resolve_script(script, bindings) do
      {:ok, s} -> [{s, %{}}]
      :error -> []
    end
  end

  defp extract_compare_bash_calls({:compare_bash, _, [script, opts]}, bindings) do
    case resolve_script(script, bindings) do
      {:ok, s} -> [{s, eval_opts(opts)}]
      :error -> []
    end
  end

  defp extract_compare_bash_calls(_, _bindings), do: []

  # Resolve a script expression — either a literal or a variable reference
  defp resolve_script({var_name, _, nil}, bindings) when is_atom(var_name) do
    case Map.fetch(bindings, var_name) do
      {:ok, value} -> {:ok, value}
      :error -> eval_script({var_name, [], nil})
    end
  end

  defp resolve_script(ast, _bindings), do: eval_script(ast)

  # Evaluate a script expression to a string
  defp eval_script(ast) do
    try do
      {value, _} = Code.eval_quoted(ast)

      if is_binary(value) do
        {:ok, value}
      else
        :error
      end
    rescue
      _ -> :error
    end
  end

  defp eval_opts(ast) do
    try do
      {value, _} = Code.eval_quoted(ast)
      Enum.into(value, %{})
    rescue
      _ -> %{}
    end
  end
end

BashCaseExtractor.run()
