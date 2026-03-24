defmodule JustBash.Security.BudgetTest do
  use ExUnit.Case, async: true

  alias JustBash.Limits
  alias JustBash.Security.Budget
  alias JustBash.Security.Violation

  test "limit violations are stored as typed security violations" do
    bash = JustBash.new(security: [max_output_bytes: 1])

    {result, bash} = JustBash.exec(bash, "printf 12")

    assert result.exit_code != 0
    assert %Violation{} = result.violation
    assert result.violation.kind == :output_limit_exceeded
    assert %Violation{} = Limits.current_violation(bash)
    assert Limits.current_violation(bash).kind == :output_limit_exceeded
    assert Limits.current_violation(bash).message =~ "output limit exceeded"
  end

  test "top-level exec resets the security budget counters" do
    bash = JustBash.new(security: [max_steps: 10])

    {_, bash} = JustBash.exec(bash, "echo one; echo two")
    assert bash.interpreter.budget.step_count == 2

    {_, bash} = JustBash.exec(bash, "echo reset")
    assert bash.interpreter.budget.step_count == 1
  end

  describe "Budget.new/0" do
    test "returns a fresh budget with zeroed counters and no violation" do
      budget = Budget.new()

      assert budget.output_bytes == 0
      assert budget.step_count == 0
      assert budget.violation == nil
    end
  end

  describe "Limits helper functions" do
    test "limit_error?/1 returns false when no violation is present" do
      bash = JustBash.new()
      refute Limits.limit_error?(bash)
    end

    test "limit_error?/1 returns true after a violation" do
      bash = JustBash.new()
      bash = Limits.put_limit_error(bash, "test error\n")
      assert Limits.limit_error?(bash)
    end

    test "current_violation_message/1 returns nil when no violation" do
      bash = JustBash.new()
      assert Limits.current_violation_message(bash) == nil
    end

    test "current_violation_message/1 returns the message string" do
      bash = JustBash.new()
      bash = Limits.put_limit_error(bash, "something broke\n")
      assert Limits.current_violation_message(bash) == "something broke\n"
    end

    test "reset_budget/1 clears violations and counters" do
      bash = JustBash.new()
      bash = Limits.put_limit_error(bash, "error\n")
      assert Limits.limit_error?(bash)

      bash = Limits.reset_budget(bash)
      refute Limits.limit_error?(bash)
      assert bash.interpreter.budget.step_count == 0
      assert bash.interpreter.budget.output_bytes == 0
    end

    test "violation/2 constructs a Violation with empty metadata" do
      v = Limits.violation(:test_kind, "test message")
      assert %Violation{kind: :test_kind, message: "test message", metadata: %{}} = v
    end

    test "violation/3 constructs a Violation with custom metadata" do
      v = Limits.violation(:test_kind, "msg", %{extra: true})
      assert v.metadata == %{extra: true}
    end

    test "limit_result/1 from Violation includes the violation struct" do
      v = Limits.violation(:test, "err\n")
      result = Limits.limit_result(v)

      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "err\n"
      assert result.violation == v
    end

    test "limit_result/1 from string has nil violation" do
      result = Limits.limit_result("plain error\n")

      assert result.exit_code == 1
      assert result.stderr == "plain error\n"
      assert result.violation == nil
    end
  end
end
