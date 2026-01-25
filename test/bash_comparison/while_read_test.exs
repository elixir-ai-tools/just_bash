defmodule JustBash.BashComparison.WhileReadTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "while read loops" do
    test "basic while read" do
      compare_bash(~S[echo -e "a\nb\nc" | while read x; do echo "got: $x"; done])
    end

    test "while read terminates on EOF" do
      compare_bash(~S[echo -e "1\n2\n3" | while read n; do echo $n; done; echo done])
    end

    test "while read with head" do
      compare_bash(~S[echo -e "1\n2\n3\n4\n5" | head -3 | while read x; do echo "x=$x"; done])
    end

    test "read returns 1 on empty input" do
      compare_bash(~S[echo "" | read x; echo $?])
    end
  end
end
