defmodule JustBash.Security.ResourceLimitsTest do
  use ExUnit.Case, async: true

  alias JustBash.MockHttpClient

  describe "output quotas" do
    test "stdout output is rejected when it exceeds the configured limit" do
      bash = JustBash.new(security: [max_output_bytes: 5])

      {result, _} = JustBash.exec(bash, "printf 123456")

      assert result.exit_code != 0
      assert result.stdout == ""
      assert result.stderr =~ "output limit exceeded"
    end

    test "output limit stops later commands in the same script" do
      bash = JustBash.new(security: [max_output_bytes: 5])

      {result, _} = JustBash.exec(bash, "printf 123456; echo after")

      assert result.exit_code != 0
      refute result.stdout =~ "after"
      assert result.stderr =~ "output limit exceeded"
    end

    test "stderr counts against the shared output limit" do
      bash = JustBash.new(security: [max_output_bytes: 20])

      {result, _} = JustBash.exec(bash, "missing_command; echo after")

      assert result.exit_code != 0
      refute result.stdout =~ "after"
      assert result.stderr =~ "output limit exceeded"
    end

    test "nested eval output burns the same output budget" do
      bash = JustBash.new(security: [max_output_bytes: 5])

      {result, _} = JustBash.exec(bash, "eval 'printf 123456'; echo after")

      assert result.exit_code != 0
      refute result.stdout =~ "after"
      assert result.stderr =~ "output limit exceeded"
    end

    test "exit trap output burns the same output budget" do
      bash = JustBash.new(security: [max_output_bytes: 5])

      {result, _} = JustBash.exec(bash, "trap 'printf 6789' EXIT; printf 12")

      assert result.exit_code != 0
      assert result.stderr =~ "output limit exceeded"
    end
  end

  describe "filesystem quotas" do
    test "file writes are rejected when they exceed max_file_bytes" do
      bash = JustBash.new(security: [max_file_bytes: 4])

      {result, bash} = JustBash.exec(bash, "printf hello > /tmp/too-big")

      assert result.exit_code != 0
      assert result.stderr =~ "file size limit exceeded"

      {cat_result, _} = JustBash.exec(bash, "cat /tmp/too-big")
      assert cat_result.exit_code != 0
    end

    test "filesystem writes are rejected when they exceed max_total_fs_bytes" do
      bash = JustBash.new(security: [max_total_fs_bytes: 5])

      {result, bash} = JustBash.exec(bash, "printf abc > /tmp/a; printf def > /tmp/b")

      assert result.exit_code != 0
      assert result.stderr =~ "filesystem size limit exceeded"

      {first_file, bash} = JustBash.exec(bash, "cat /tmp/a")
      assert first_file.stdout == "abc"

      {second_file, _} = JustBash.exec(bash, "cat /tmp/b")
      assert second_file.exit_code != 0
    end

    test "append operations are rejected when they exceed max_file_bytes" do
      bash = JustBash.new(files: %{"/tmp/file" => "ab"}, security: [max_file_bytes: 3])

      {result, bash} = JustBash.exec(bash, "printf cd | tee -a /tmp/file")

      assert result.exit_code != 0
      assert result.stderr =~ "file size limit exceeded"

      {cat_result, _} = JustBash.exec(bash, "cat /tmp/file")
      assert cat_result.stdout == "ab"
    end

    test "copy operations are rejected when they exceed max_total_fs_bytes" do
      bash = JustBash.new(files: %{"/tmp/src" => "abc"}, security: [max_total_fs_bytes: 5])

      {result, bash} = JustBash.exec(bash, "cp /tmp/src /tmp/dest")

      assert result.exit_code != 0
      assert result.stderr =~ "filesystem size limit exceeded"

      {cat_result, _} = JustBash.exec(bash, "cat /tmp/dest")
      assert cat_result.exit_code != 0
    end
  end

  describe "parser and expansion quotas" do
    test "input is rejected when it exceeds max_input_bytes" do
      bash = JustBash.new(security: [max_input_bytes: 5])

      {result, _} = JustBash.exec(bash, "echo hello")

      assert result.exit_code != 0
      assert result.stderr =~ "input size limit exceeded"
    end

    test "input is rejected when it exceeds max_tokens" do
      bash = JustBash.new(security: [max_tokens: 3])

      {result, _} = JustBash.exec(bash, "echo a b c")

      assert result.exit_code != 0
      assert result.stderr =~ "token limit exceeded"
    end

    test "brace expansion is rejected when it exceeds max_expanded_words" do
      bash = JustBash.new(security: [max_expanded_words: 3])

      {result, _} = JustBash.exec(bash, "echo {a,b,c,d}")

      assert result.exit_code != 0
      assert result.stderr =~ "expansion limit exceeded"
    end

    test "source uses the same input byte limit" do
      bash =
        JustBash.new(files: %{"/tmp/huge.sh" => "echo hello\n"}, security: [max_input_bytes: 5])

      {result, _} = JustBash.exec(bash, "source /tmp/huge.sh")

      assert result.exit_code != 0
      assert result.stderr =~ "input size limit exceeded"
    end

    test "eval uses the same token limit" do
      bash = JustBash.new(security: [max_tokens: 3])

      {result, _} = JustBash.exec(bash, "eval 'echo a b c'")

      assert result.exit_code != 0
      assert result.stderr =~ "token limit exceeded"
    end

    test "brace range expansion is rejected when it exceeds max_expanded_words" do
      bash = JustBash.new(security: [max_expanded_words: 3])

      {result, _} = JustBash.exec(bash, "echo {1..4}")

      assert result.exit_code != 0
      assert result.stderr =~ "expansion limit exceeded"
    end

    test "cartesian brace expansion is rejected when it exceeds max_expanded_words" do
      bash = JustBash.new(security: [max_expanded_words: 3])

      {result, _} = JustBash.exec(bash, "echo {a,b}{c,d}")

      assert result.exit_code != 0
      assert result.stderr =~ "expansion limit exceeded"
    end
  end

  describe "execution depth quotas" do
    test "nested eval recursion is rejected when it exceeds max_exec_depth" do
      bash = JustBash.new(security: [max_exec_depth: 4])

      {result, _} =
        JustBash.exec(
          bash,
          ~s(x='eval "$x"'; eval "$x")
        )

      assert result.exit_code != 0
      assert result.stderr =~ "maximum execution depth exceeded"
    end

    test "nested command substitution is rejected when it exceeds max_exec_depth" do
      bash = JustBash.new(security: [max_exec_depth: 2])

      {result, _} = JustBash.exec(bash, "echo $(echo $(echo hi))")

      assert result.exit_code != 0
      assert result.stderr =~ "maximum execution depth exceeded"
    end
  end

  describe "network body quotas" do
    test "curl rejects oversized response bodies sent to stdout" do
      bash =
        JustBash.new(
          network: %{enabled: true, allow_list: ["example.com"]},
          http_client: MockHttpClient,
          security: [max_http_body_bytes: 4]
        )

      MockHttpClient.with_mock(
        fn _req -> {:ok, %{status: 200, headers: %{}, body: "hello"}} end,
        fn ->
          {result, _} = JustBash.exec(bash, "curl https://example.com/data")

          assert result.exit_code != 0
          assert result.stdout == ""
          assert result.stderr =~ "HTTP body size limit exceeded"
        end
      )
    end

    test "curl rejects oversized response bodies before writing files" do
      bash =
        JustBash.new(
          network: %{enabled: true, allow_list: ["example.com"]},
          http_client: MockHttpClient,
          security: [max_http_body_bytes: 4]
        )

      MockHttpClient.with_mock(
        fn _req -> {:ok, %{status: 200, headers: %{}, body: "hello"}} end,
        fn ->
          {result, bash} = JustBash.exec(bash, "curl -o /tmp/out.txt https://example.com/data")

          assert result.exit_code != 0
          assert result.stderr =~ "HTTP body size limit exceeded"

          {cat_result, _} = JustBash.exec(bash, "cat /tmp/out.txt")
          assert cat_result.exit_code != 0
        end
      )
    end

    test "wget rejects oversized response bodies before writing files" do
      bash =
        JustBash.new(
          network: %{enabled: true, allow_list: ["example.com"]},
          http_client: MockHttpClient,
          security: [max_http_body_bytes: 4]
        )

      MockHttpClient.with_mock(
        fn _req -> {:ok, %{status: 200, headers: %{}, body: "hello"}} end,
        fn ->
          {result, bash} = JustBash.exec(bash, "wget https://example.com/data")

          assert result.exit_code != 0
          assert result.stderr =~ "HTTP body size limit exceeded"

          {cat_result, _} = JustBash.exec(bash, "cat /home/user/data")
          assert cat_result.exit_code != 0
        end
      )
    end
  end

  describe "regex quotas" do
    test "grep rejects oversized regex patterns" do
      bash = JustBash.new(security: [max_regex_pattern_bytes: 4])

      {result, _} = JustBash.exec(bash, "printf hello | grep hello")

      assert result.exit_code != 0
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "grep rejects oversized regex input" do
      bash = JustBash.new(security: [max_regex_input_bytes: 4])

      {result, _} = JustBash.exec(bash, "printf hello | grep h")

      assert result.exit_code != 0
      assert result.stderr =~ "regex input size limit exceeded"
    end

    test "sed rejects oversized regex patterns" do
      bash = JustBash.new(security: [max_regex_pattern_bytes: 4])

      {result, _} = JustBash.exec(bash, "printf hello | sed 's/hello/hi/'")

      assert result.exit_code != 0
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "sed rejects oversized regex input" do
      bash = JustBash.new(security: [max_regex_input_bytes: 4])

      {result, _} = JustBash.exec(bash, "printf hello | sed 's/h/H/'")

      assert result.exit_code != 0
      assert result.stderr =~ "regex input size limit exceeded"
    end

    test "awk rejects oversized regex patterns" do
      bash = JustBash.new(security: [max_regex_pattern_bytes: 4])

      {result, _} = JustBash.exec(bash, "printf hello | awk '/hello/{print}'")

      assert result.exit_code != 0
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "awk rejects oversized regex input" do
      bash = JustBash.new(security: [max_regex_input_bytes: 4])

      {result, _} = JustBash.exec(bash, "printf hello | awk '/h/{print}'")

      assert result.exit_code != 0
      assert result.stderr =~ "regex input size limit exceeded"
    end
  end

  describe "glob and file-walk quotas" do
    test "glob expansion is rejected when it exceeds max_glob_matches" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/a.txt" => "a\n",
            "/tmp/b.txt" => "b\n",
            "/tmp/c.txt" => "c\n"
          },
          security: [max_glob_matches: 2]
        )

      {result, _} = JustBash.exec(bash, "echo /tmp/*.txt")

      assert result.exit_code != 0
      assert result.stdout == ""
      assert result.stderr =~ "glob match limit exceeded"
    end

    test "glob limit stops later commands in the same script" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/a.txt" => "a\n",
            "/tmp/b.txt" => "b\n",
            "/tmp/c.txt" => "c\n"
          },
          security: [max_glob_matches: 2]
        )

      {result, _} = JustBash.exec(bash, "echo /tmp/*.txt; echo after")

      assert result.exit_code != 0
      refute result.stdout =~ "after"
      assert result.stderr =~ "glob match limit exceeded"
    end

    test "grep -r is rejected when recursive walk exceeds max_file_walk_entries" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "hello\n",
            "/data/b.txt" => "hello\n",
            "/data/c.txt" => "hello\n"
          },
          security: [max_file_walk_entries: 2]
        )

      {result, _} = JustBash.exec(bash, "grep -r hello /data")

      assert result.exit_code != 0
      assert result.stdout == ""
      assert result.stderr =~ "file walk limit exceeded"
    end

    test "find is rejected when recursive walk exceeds max_file_walk_entries" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "a\n",
            "/data/b.txt" => "b\n",
            "/data/c.txt" => "c\n"
          },
          security: [max_file_walk_entries: 2]
        )

      {result, _} = JustBash.exec(bash, "find /data")

      assert result.exit_code != 0
      assert result.stdout == ""
      assert result.stderr =~ "file walk limit exceeded"
    end
  end

  describe "environment and array quotas" do
    test "export rejects oversized environment growth" do
      bash = JustBash.new(security: [max_env_bytes: 20])

      {result, bash} = JustBash.exec(bash, "export BIG=abcdefghijklmnop")

      assert result.exit_code != 0
      assert result.stderr =~ "environment size limit exceeded"

      {check_result, _} = JustBash.exec(bash, "printenv BIG")
      assert check_result.stdout == ""
    end

    test "shell assignment rejects oversized environment growth" do
      bash = JustBash.new(security: [max_env_bytes: 20])

      {result, bash} = JustBash.exec(bash, "BIG=abcdefghijklmnop")

      assert result.exit_code != 0
      assert result.stderr =~ "environment size limit exceeded"

      {check_result, _} = JustBash.exec(bash, "printenv BIG")
      assert check_result.stdout == ""
    end

    test "array assignment rejects too many entries" do
      bash = JustBash.new(security: [max_array_entries: 2])

      {result, bash} = JustBash.exec(bash, "arr=(a b c)")

      assert result.exit_code != 0
      assert result.stderr =~ "array entry limit exceeded"

      {check_result, _} = JustBash.exec(bash, "echo ${arr[0]}${arr[1]}${arr[2]}")
      assert String.trim(check_result.stdout) == ""
    end

    test "array assignment rejects oversized array values" do
      bash = JustBash.new(security: [max_array_bytes: 10])

      {result, bash} = JustBash.exec(bash, "arr=(abcdefghijk)")

      assert result.exit_code != 0
      assert result.stderr =~ "array size limit exceeded"

      {check_result, _} = JustBash.exec(bash, "echo ${arr[0]}")
      assert String.trim(check_result.stdout) == ""
    end
  end

  describe "shared execution step budget" do
    test "sequential commands stop when max_steps is exceeded" do
      bash = JustBash.new(security: [max_steps: 2])

      {result, _} = JustBash.exec(bash, "echo one; echo two; echo three")

      assert result.exit_code != 0
      assert result.stdout == "one\ntwo\n"
      assert result.stderr =~ "execution step limit exceeded"
    end

    test "loop bodies burn the shared execution step budget" do
      bash = JustBash.new(security: [max_steps: 3])

      {result, _} = JustBash.exec(bash, "for x in a b c d; do echo $x; done")

      assert result.exit_code != 0
      assert result.stdout == "a\nb\nc\n"
      assert result.stderr =~ "execution step limit exceeded"
    end

    test "nested eval shares the same execution step budget" do
      bash = JustBash.new(security: [max_steps: 2])

      {result, _} = JustBash.exec(bash, "eval 'echo one; echo two'; echo three")

      assert result.exit_code != 0
      assert result.stdout == "one\ntwo\n"
      assert result.stderr =~ "execution step limit exceeded"
    end
  end

  describe "parser AST quotas" do
    test "parser rejects oversized AST node counts" do
      bash = JustBash.new(security: [max_ast_nodes: 5])

      {result, _} = JustBash.exec(bash, "echo one; echo two; echo three")

      assert result.exit_code != 0
      assert result.stderr =~ "AST node limit exceeded"
    end

    test "parser rejects excessive nesting depth" do
      bash = JustBash.new(security: [max_nesting_depth: 1])

      {result, _} = JustBash.exec(bash, "if true; then if true; then echo hi; fi; fi")

      assert result.exit_code != 0
      assert result.stderr =~ "nesting depth limit exceeded"
    end

    test "source uses the same AST node limit" do
      bash =
        JustBash.new(
          files: %{"/tmp/nodes.sh" => "echo one; echo two; echo three\n"},
          security: [max_ast_nodes: 5]
        )

      {result, _} = JustBash.exec(bash, "source /tmp/nodes.sh")

      assert result.exit_code != 0
      assert result.stderr =~ "AST node limit exceeded"
    end
  end

  describe "jq quotas" do
    test "jq rejects too many emitted results" do
      bash = JustBash.new(files: %{"/data.json" => "[1,2,3]"}, security: [max_jq_results: 2])

      {result, _} = JustBash.exec(bash, "jq '.[]' /data.json")

      assert result.exit_code != 0
      assert result.stderr =~ "jq result limit exceeded"
    end

    test "jq rejects excessive recursive descent depth" do
      bash =
        JustBash.new(
          files: %{"/data.json" => ~s({"a":{"b":{"c":1}}})},
          security: [max_jq_depth: 2]
        )

      {result, _} = JustBash.exec(bash, "jq '..' /data.json")

      assert result.exit_code != 0
      assert result.stderr =~ "jq recursion depth limit exceeded"
    end

    test "jq rejects oversized JSON input before decode" do
      bash =
        JustBash.new(
          files: %{"/data.json" => ~s({"name":"hello"})},
          security: [max_jq_input_bytes: 8]
        )

      {result, _} = JustBash.exec(bash, "jq '.' /data.json")

      assert result.exit_code != 0
      assert result.stderr =~ "jq input size limit exceeded"
    end

    test "jq rejects excessive JSON nesting before decode" do
      bash =
        JustBash.new(
          files: %{"/data.json" => ~s({"a":{"b":{"c":1}}})},
          security: [max_jq_input_depth: 2]
        )

      {result, _} = JustBash.exec(bash, "jq '.' /data.json")

      assert result.exit_code != 0
      assert result.stderr =~ "jq input nesting limit exceeded"
    end

    test "jq rejects oversized regex patterns" do
      bash =
        JustBash.new(
          files: %{"/data.json" => ~S("hello")},
          security: [max_regex_pattern_bytes: 4]
        )

      {result, _} = JustBash.exec(bash, ~s|jq 'test("hello")' /data.json|)

      assert result.exit_code != 0
      assert result.stderr =~ "regex pattern size limit exceeded"
    end

    test "jq rejects oversized regex input" do
      bash =
        JustBash.new(files: %{"/data.json" => ~S("hello")}, security: [max_regex_input_bytes: 4])

      {result, _} = JustBash.exec(bash, ~s|jq 'test("h")' /data.json|)

      assert result.exit_code != 0
      assert result.stderr =~ "regex input size limit exceeded"
    end

    test "jq rejects excessive intermediate work items" do
      bash = JustBash.new(files: %{"/data.json" => "[1,2,3]"}, security: [max_jq_work_items: 2])

      {result, _} = JustBash.exec(bash, ~s|jq 'map(. + 1)' /data.json|)

      assert result.exit_code != 0
      assert result.stderr =~ "jq work item limit exceeded"
    end
  end

  describe "violation metadata in exec results" do
    test "output limit violation is returned in exec result" do
      bash = JustBash.new(security: [max_output_bytes: 5])

      {result, _} = JustBash.exec(bash, "printf 123456")

      assert %JustBash.Security.Violation{} = result.violation
      assert result.violation.kind == :output_limit_exceeded
      assert result.violation.message =~ "output limit exceeded"
    end

    test "step limit violation is returned in exec result" do
      bash = JustBash.new(security: [max_steps: 1])

      {result, _} = JustBash.exec(bash, "echo a; echo b; echo c")

      assert %JustBash.Security.Violation{} = result.violation
      assert result.violation.kind == :execution_step_limit_exceeded
    end

    test "no violation returns nil" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo hello")

      assert result.violation == nil
    end
  end
end
