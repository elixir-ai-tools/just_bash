defmodule JustBash.ResultTest do
  use ExUnit.Case, async: true
  alias JustBash.Result

  describe "new/1" do
    test "creates default result" do
      result = Result.new()
      assert result.stdout == ""
      assert result.stderr == ""
      assert result.exit_code == 0
      assert result.signal == nil
    end

    test "creates result with custom attributes" do
      result = Result.new(stdout: "hello\n", exit_code: 1, signal: {:break, 2})
      assert result.stdout == "hello\n"
      assert result.stderr == ""
      assert result.exit_code == 1
      assert result.signal == {:break, 2}
    end
  end

  describe "ok/1" do
    test "creates successful result with stdout" do
      result = Result.ok("output\n")
      assert result.stdout == "output\n"
      assert result.stderr == ""
      assert result.exit_code == 0
      assert result.signal == nil
    end
  end

  describe "error/2" do
    test "creates error result with stderr" do
      result = Result.error("error message\n", 127)
      assert result.stdout == ""
      assert result.stderr == "error message\n"
      assert result.exit_code == 127
      assert result.signal == nil
    end

    test "defaults to exit code 1" do
      result = Result.error("error")
      assert result.exit_code == 1
    end
  end

  describe "break/1" do
    test "creates break signal" do
      result = Result.break(3)
      assert result.signal == {:break, 3}
      assert result.exit_code == 0
    end

    test "defaults to level 1" do
      result = Result.break()
      assert result.signal == {:break, 1}
    end
  end

  describe "continue/1" do
    test "creates continue signal" do
      result = Result.continue(2)
      assert result.signal == {:continue, 2}
    end
  end

  describe "return/1" do
    test "creates return signal" do
      result = Result.return(42)
      assert result.signal == {:return, 42}
      assert result.exit_code == 42
    end
  end

  describe "signal predicates" do
    test "has_signal?/1" do
      assert Result.has_signal?(Result.break())
      assert Result.has_signal?(Result.continue())
      assert Result.has_signal?(Result.return())
      refute Result.has_signal?(Result.ok())
    end

    test "break?/1" do
      assert Result.break?(Result.break())
      refute Result.break?(Result.continue())
      refute Result.break?(Result.ok())
    end

    test "continue?/1" do
      assert Result.continue?(Result.continue())
      refute Result.continue?(Result.break())
    end

    test "return?/1" do
      assert Result.return?(Result.return())
      refute Result.return?(Result.break())
    end
  end

  describe "decrement_signal/1" do
    test "decrements break level" do
      result = Result.break(3) |> Result.decrement_signal()
      assert result.signal == {:break, 2}
    end

    test "clears break when level reaches 0" do
      result = Result.break(1) |> Result.decrement_signal()
      assert result.signal == nil
    end

    test "decrements continue level" do
      result = Result.continue(2) |> Result.decrement_signal()
      assert result.signal == {:continue, 1}
    end

    test "clears continue when level reaches 0" do
      result = Result.continue(1) |> Result.decrement_signal()
      assert result.signal == nil
    end

    test "does not affect return signal" do
      result = Result.return(5) |> Result.decrement_signal()
      assert result.signal == {:return, 5}
    end

    test "does not affect no signal" do
      result = Result.ok() |> Result.decrement_signal()
      assert result.signal == nil
    end
  end

  describe "merge_output/2" do
    test "concatenates stdout and stderr" do
      target = Result.new(stdout: "a", stderr: "x")
      source = Result.new(stdout: "b", stderr: "y", exit_code: 1)
      merged = Result.merge_output(target, source)
      assert merged.stdout == "ab"
      assert merged.stderr == "xy"
      assert merged.exit_code == 1
    end

    test "preserves signal from source if present" do
      target = Result.ok("a")
      source = Result.new(stdout: "b", signal: {:break, 1})
      merged = Result.merge_output(target, source)
      assert merged.signal == {:break, 1}
    end

    test "preserves signal from target if source has none" do
      target = Result.new(stdout: "a", signal: {:break, 2})
      source = Result.ok("b")
      merged = Result.merge_output(target, source)
      assert merged.signal == {:break, 2}
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips plain result" do
      original = Result.new(stdout: "hello", stderr: "error", exit_code: 42)
      map = Result.to_map(original)
      assert map == %{stdout: "hello", stderr: "error", exit_code: 42}
      restored = Result.from_map(map)
      assert restored == original
    end

    test "round-trips break signal" do
      original = Result.break(3)
      map = Result.to_map(original)
      assert map.__break__ == 3
      restored = Result.from_map(map)
      assert restored == original
    end

    test "round-trips continue signal" do
      original = Result.continue(2)
      map = Result.to_map(original)
      assert map.__continue__ == 2
      restored = Result.from_map(map)
      assert restored == original
    end

    test "round-trips return signal" do
      original = Result.return(5)
      map = Result.to_map(original)
      assert map.__return__ == 5
      restored = Result.from_map(map)
      assert restored == original
    end
  end
end
