defmodule JustBash.Integration.RealWorldTest do
  @moduledoc """
  Integration tests based on real-world AI agent scripts.

  These tests capture patterns that agents commonly use when working with
  JustBash, including jq pipelines, glob patterns, PIPESTATUS checks,
  and nested command substitution.
  """

  use ExUnit.Case, async: true

  describe "workflow inspection scripts" do
    setup do
      bash =
        JustBash.new(
          files: %{
            "/knock/workflows/welcome-email/workflow.json" =>
              ~S'{"steps": [{"type": "email", "channel_type": "email", "ref": "send_welcome", "channel_key": "main-email"}, {"type": "delay", "ref": "wait_1d"}]}',
            "/knock/workflows/notification/workflow.json" =>
              ~S'{"steps": [{"type": "in_app_feed", "channel_type": "in_app", "ref": "notify"}]}',
            "/knock/workflows/sms-alert/workflow.json" =>
              ~S'{"steps": [{"type": "sms", "channel_type": "sms", "ref": "text_alert"}]}',
            "/knock/workflows/drip-campaign/workflow.json" =>
              ~S'{"steps": [{"type": "email", "channel_type": "email", "ref": "day1", "channel_key": "marketing"}, {"type": "delay", "ref": "wait_3d"}, {"type": "email", "channel_type": "email", "ref": "day4", "channel_key": "marketing"}]}'
          }
        )

      {:ok, bash: bash}
    end

    test "grep -r finds in_app_feed workflows", %{bash: bash} do
      {result, _} =
        JustBash.exec(bash, ~S'grep -r "in_app_feed" /knock/workflows/*/workflow.json')

      assert result.exit_code == 0
      assert result.stdout =~ "notification/workflow.json"
      assert result.stdout =~ "in_app_feed"
    end

    test "loop over workflow directories with glob", %{bash: bash} do
      script = """
      for workflow in /knock/workflows/*/; do
        if [ -f "$workflow/workflow.json" ]; then
          workflow_key=$(basename "$workflow")
          echo "$workflow_key"
        fi
      done
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0

      lines = String.split(result.stdout, "\n", trim: true)
      assert "welcome-email" in lines
      assert "notification" in lines
      assert "sms-alert" in lines
      assert "drip-campaign" in lines
    end

    test "find email workflows using grep and jq", %{bash: bash} do
      script = """
      for workflow in /knock/workflows/*/; do
        if [ -f "$workflow/workflow.json" ]; then
          workflow_key=$(basename "$workflow")
          if grep -q '"channel_type".*:.*"email"' "$workflow/workflow.json"; then
            echo "$workflow_key has email"
          else
            echo "$workflow_key no email"
          fi
        fi
      done
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0
      assert result.stdout =~ "welcome-email has email"
      assert result.stdout =~ "notification no email"
      assert result.stdout =~ "sms-alert no email"
      assert result.stdout =~ "drip-campaign has email"
    end

    test "jq select with channel_type filter", %{bash: bash} do
      script =
        "cat /knock/workflows/welcome-email/workflow.json | jq -r '.steps[] | select(.channel_type == \"email\") | .ref'"

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0
      assert result.stdout == "send_welcome\n"
    end

    test "jq with string interpolation in output", %{bash: bash} do
      script =
        "cat /knock/workflows/drip-campaign/workflow.json | jq -r '.steps[] | select(.channel_type == \"email\") | \"Email step: \\(.ref) (channel: \\(.channel_key))\"'"

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0
      assert result.stdout =~ "Email step: day1 (channel: marketing)"
      assert result.stdout =~ "Email step: day4 (channel: marketing)"
    end
  end

  describe "command substitution with nested quotes" do
    setup do
      bash =
        JustBash.new(
          files: %{
            "/data.json" => ~S'{"items": [{"type": "email", "name": "test"}]}'
          }
        )

      {:ok, bash: bash}
    end

    test "quoted command substitution with jq select", %{bash: bash} do
      # This pattern previously failed - inner quotes weren't handled correctly
      script = ~S'''
      echo "$(cat /data.json | jq '.items[] | select(.type == "email")')"
      '''

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0
      assert result.stdout =~ "email"
      assert result.stdout =~ "test"
    end

    test "test -z with quoted command substitution containing jq", %{bash: bash} do
      script = ~S'''
      if [ -z "$(cat /data.json | jq -r '.items[] | select(.type == "email")')" ]; then
        echo "empty"
      else
        echo "found"
      fi
      '''

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0
      assert result.stdout == "found\n"
    end

    test "variable with path inside quoted command substitution", %{bash: bash} do
      script = """
      file=/data.json
      echo "$(cat "$file" | jq '.items')"
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0
      assert result.stdout =~ "email"
    end

    test "nested command substitution with quotes and pipes", %{bash: bash} do
      script = ~S'''
      result="$(cat /data.json | jq -r '.items[] | select(.type == "email") | .name')"
      echo "Result: $result"
      '''

      {result, _} = JustBash.exec(bash, script)
      assert result.exit_code == 0
      assert result.stdout == "Result: test\n"
    end
  end

  describe "PIPESTATUS usage patterns" do
    test "check jq exit status in pipeline" do
      bash =
        JustBash.new(
          files: %{"/valid.json" => ~S'{"key": "value"}', "/invalid.txt" => "not json"}
        )

      script = """
      cat /valid.json | jq '.'
      echo "jq exit: ${PIPESTATUS[1]}"
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "jq exit: 0"
    end

    test "detect jq failure with PIPESTATUS", %{} do
      bash = JustBash.new(files: %{"/bad.txt" => "not json"})

      script = """
      cat /bad.txt | jq '.' 2>/dev/null
      if [ ${PIPESTATUS[1]} -ne 0 ]; then
        echo "jq failed"
      fi
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "jq failed"
    end

    test "combined PIPESTATUS and output check", %{} do
      bash =
        JustBash.new(
          files: %{
            "/empty.json" => ~S'{"items": []}',
            "/full.json" => ~S'{"items": [{"x": 1}]}'
          }
        )

      # Pattern: check both that jq succeeded AND produced output
      script = ~S'''
      check_items() {
        cat "$1" | jq -r '.items[]' 2>/dev/null
        if [ ${PIPESTATUS[1]} -ne 0 ] || [ -z "$(cat "$1" | jq -r '.items[]' 2>/dev/null)" ]; then
          echo "No items in $1"
        fi
      }
      check_items /empty.json
      check_items /full.json
      '''

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "No items in /empty.json"
      refute result.stdout =~ "No items in /full.json"
    end
  end

  describe "glob patterns in scripts" do
    test "directory wildcard with trailing slash" do
      bash =
        JustBash.new(
          files: %{
            "/projects/alpha/config.json" => "{}",
            "/projects/beta/config.json" => "{}",
            "/projects/gamma/config.json" => "{}"
          }
        )

      script = """
      for dir in /projects/*/; do
        echo "$(basename "$dir")"
      done
      """

      {result, _} = JustBash.exec(bash, script)
      lines = String.split(result.stdout, "\n", trim: true)

      assert "alpha" in lines
      assert "beta" in lines
      assert "gamma" in lines
    end

    test "nested directory wildcards" do
      bash =
        JustBash.new(
          files: %{
            "/a/x/file.txt" => "ax",
            "/a/y/file.txt" => "ay",
            "/b/x/file.txt" => "bx"
          }
        )

      script = """
      for f in /*/x/file.txt; do
        cat "$f"
      done
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "ax"
      assert result.stdout =~ "bx"
      refute result.stdout =~ "ay"
    end

    test "wildcard in middle of path" do
      bash =
        JustBash.new(
          files: %{
            "/data/2024/report.csv" => "2024 data",
            "/data/2025/report.csv" => "2025 data"
          }
        )

      {result, _} = JustBash.exec(bash, "cat /data/*/report.csv")
      assert result.stdout =~ "2024 data"
      assert result.stdout =~ "2025 data"
    end
  end

  describe "complete agent workflow patterns" do
    test "workflow email step inspection script" do
      bash =
        JustBash.new(
          files: %{
            "/knock/workflows/foo/workflow.json" =>
              ~S'{"steps": [{"type": "email", "channel_type": "email", "ref": "send", "channel_key": "main"}]}',
            "/knock/workflows/bar/workflow.json" =>
              ~S'{"steps": [{"type": "push", "channel_type": "push", "ref": "notify"}]}'
          }
        )

      # Use a simpler pattern that avoids the complex jq string interpolation
      script = """
      for workflow_dir in foo bar; do
        echo "=== $workflow_dir ==="
        output=$(cat "/knock/workflows/$workflow_dir/workflow.json" | jq -r '.steps[] | select(.channel_type == "email") | .ref' 2>/dev/null)
        if [ -n "$output" ]; then
          echo "Email: $output"
        else
          echo "No email steps"
        fi
      done
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout =~ "=== foo ==="
      assert result.stdout =~ "Email: send"
      assert result.stdout =~ "=== bar ==="
      assert result.stdout =~ "No email steps"
    end

    test "find and count workflows by type" do
      bash =
        JustBash.new(
          files: %{
            "/workflows/a/workflow.json" => ~S'{"steps": [{"channel_type": "email"}]}',
            "/workflows/b/workflow.json" => ~S'{"steps": [{"channel_type": "email"}]}',
            "/workflows/c/workflow.json" => ~S'{"steps": [{"channel_type": "sms"}]}'
          }
        )

      script = """
      email_count=0
      for wf in /workflows/*/workflow.json; do
        if grep -q '"channel_type".*"email"' "$wf"; then
          email_count=$((email_count + 1))
        fi
      done
      echo "Email workflows: $email_count"
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "Email workflows: 2\n"
    end
  end
end
