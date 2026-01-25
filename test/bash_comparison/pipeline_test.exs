defmodule JustBash.BashComparison.PipelineTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "pipeline comparison" do
    test "simple pipe" do
      compare_bash("echo hello | cat")
    end

    test "multiple pipes" do
      compare_bash("echo 'c\na\nb' | sort | head -1")
    end

    test "with grep" do
      compare_bash("echo -e 'foo\nbar\nbaz' | grep bar")
    end
  end
end
