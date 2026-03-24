defmodule JustBash.Security.ResourceLimitPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "hostile printable input never crashes the interpreter" do
    check all(script <- string(:printable, max_length: 80), max_runs: 150) do
      bash =
        JustBash.new(
          security: [
            max_input_bytes: 256,
            max_tokens: 64,
            max_ast_nodes: 128,
            max_nesting_depth: 8,
            max_expanded_words: 32,
            max_output_bytes: 128,
            max_file_bytes: 128,
            max_total_fs_bytes: 256,
            max_env_bytes: 128,
            max_array_entries: 16,
            max_array_bytes: 128,
            max_steps: 20,
            max_iterations: 5,
            max_exec_depth: 5,
            max_regex_pattern_bytes: 32,
            max_regex_input_bytes: 64,
            max_glob_matches: 8,
            max_file_walk_entries: 16,
            max_jq_results: 16,
            max_jq_depth: 8,
            max_jq_input_bytes: 128,
            max_jq_input_depth: 8,
            max_jq_work_items: 16
          ]
        )

      assert {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, _bash} =
               JustBash.exec(bash, script)

      assert is_binary(stdout)
      assert is_binary(stderr)
      assert is_integer(exit_code)
    end
  end

  property "input larger than max_input_bytes always fails closed" do
    check all(payload <- string(:alphanumeric, min_length: 11, max_length: 40), max_runs: 100) do
      bash = JustBash.new(security: [max_input_bytes: 10])

      {result, _} = JustBash.exec(bash, payload)

      assert result.exit_code != 0
      assert result.stderr =~ "input size limit exceeded"
    end
  end

  property "too many shell words always trips the token limit" do
    check all(
            words <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                min_length: 4,
                max_length: 12
              ),
            max_runs: 100
          ) do
      bash = JustBash.new(security: [max_tokens: 3])
      command = "echo " <> Enum.join(words, " ")

      {result, _} = JustBash.exec(bash, command)

      assert result.exit_code != 0
      assert result.stderr =~ "token limit exceeded"
    end
  end

  property "step limit stops execution after the allowed number of commands" do
    check all(
            words <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                min_length: 3,
                max_length: 8
              ),
            max_runs: 100
          ) do
      max_steps = length(words) - 1
      bash = JustBash.new(security: [max_steps: max_steps])

      command =
        words
        |> Enum.map_join("; ", fn word -> "echo #{word}" end)

      {result, _} = JustBash.exec(bash, command)

      assert result.exit_code != 0
      assert result.stderr =~ "execution step limit exceeded"
      assert String.split(result.stdout, "\n", trim: true) == Enum.take(words, max_steps)
    end
  end

  property "environment quota rejects oversized exports without persisting them" do
    check all(value <- string(:alphanumeric, min_length: 12, max_length: 30), max_runs: 100) do
      bash = JustBash.new(security: [max_env_bytes: 10])

      {result, bash} = JustBash.exec(bash, "export BIG=#{value}")
      {check_result, _} = JustBash.exec(bash, "printenv BIG")

      assert result.exit_code != 0
      assert result.stderr =~ "environment size limit exceeded"
      assert check_result.stdout == ""
    end
  end

  property "array entry quota rejects oversized arrays without persisting them" do
    check all(
            items <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 4),
                min_length: 3,
                max_length: 8
              ),
            max_runs: 100
          ) do
      bash = JustBash.new(security: [max_array_entries: length(items) - 1])
      command = "arr=(#{Enum.join(items, " ")})"

      {result, bash} = JustBash.exec(bash, command)
      {check_result, _} = JustBash.exec(bash, "echo ${arr[0]}")

      assert result.exit_code != 0
      assert result.stderr =~ "array entry limit exceeded"
      assert String.trim(check_result.stdout) == ""
    end
  end

  property "glob quota rejects oversized match sets and stops later commands" do
    check all(
            names <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 6),
                min_length: 3,
                max_length: 6
              ),
            max_runs: 100
          ) do
      files = Map.new(names, fn name -> {"/tmp/#{name}.txt", name} end)
      bash = JustBash.new(files: files, security: [max_glob_matches: length(names) - 1])

      {result, _} = JustBash.exec(bash, "echo /tmp/*.txt; echo after")

      assert result.exit_code != 0
      assert result.stderr =~ "glob match limit exceeded"
      refute result.stdout =~ "after"
    end
  end

  property "recursive file-walk quota rejects oversized traversals" do
    check all(
            names <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 6),
                min_length: 3,
                max_length: 6
              ),
            max_runs: 100
          ) do
      files = Map.new(names, fn name -> {"/data/#{name}.txt", "hello\n"} end)
      bash = JustBash.new(files: files, security: [max_file_walk_entries: length(names) - 1])

      {result, _} = JustBash.exec(bash, "grep -r hello /data")

      assert result.exit_code != 0
      assert result.stderr =~ "file walk limit exceeded"
    end
  end

  property "parser nesting quota rejects over-nested compound commands" do
    check all(depth <- integer(2..6), max_runs: 75) do
      bash = JustBash.new(security: [max_nesting_depth: depth - 1])

      {result, _} = JustBash.exec(bash, nested_if_script(depth))

      assert result.exit_code != 0
      assert result.stderr =~ "nesting depth limit exceeded"
    end
  end

  property "jq result quota rejects fanout larger than the configured limit" do
    check all(items <- list_of(integer(), min_length: 3, max_length: 8), max_runs: 100) do
      bash =
        JustBash.new(
          files: %{"/data.json" => Jason.encode!(items)},
          security: [max_jq_results: length(items) - 1]
        )

      {result, _} = JustBash.exec(bash, "jq '.[]' /data.json")

      assert result.exit_code != 0
      assert result.stderr =~ "jq result limit exceeded"
    end
  end

  property "jq regex quota rejects oversized patterns" do
    check all(pattern <- string(:alphanumeric, min_length: 5, max_length: 20), max_runs: 100) do
      bash =
        JustBash.new(
          files: %{"/data.json" => ~S("hello")},
          security: [max_regex_pattern_bytes: 4]
        )

      {result, _} = JustBash.exec(bash, ~s|jq 'test("#{pattern}")' /data.json|)

      assert result.exit_code != 0
      assert result.stderr =~ "regex pattern size limit exceeded"
    end
  end

  property "jq input nesting quota rejects over-nested JSON before decode" do
    check all(depth <- integer(3..8), max_runs: 75) do
      bash =
        JustBash.new(
          files: %{"/data.json" => nested_json(depth)},
          security: [max_jq_input_depth: depth - 1]
        )

      {result, _} = JustBash.exec(bash, "jq '.' /data.json")

      assert result.exit_code != 0
      assert result.stderr =~ "jq input nesting limit exceeded"
    end
  end

  defp nested_json(depth), do: do_nested_json(depth, "1")

  defp nested_if_script(depth), do: do_nested_if_script(depth, "echo ok")

  defp do_nested_json(0, acc), do: acc
  defp do_nested_json(depth, acc), do: do_nested_json(depth - 1, ~s({"a":#{acc}}))

  defp do_nested_if_script(0, body), do: body

  defp do_nested_if_script(depth, body) do
    do_nested_if_script(depth - 1, "if true; then #{body}; fi")
  end
end
