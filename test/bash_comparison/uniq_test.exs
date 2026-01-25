defmodule JustBash.BashComparison.UniqTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "uniq comparison" do
    test "basic uniq" do
      compare_bash("echo -e 'a\na\nb\nb\nc' | uniq")
    end

    # Skip: uniq -c padding differs between GNU (7 chars) and BSD (4 chars)
    @tag :skip
    test "uniq count" do
      compare_bash("echo -e 'a\na\nb' | uniq -c")
    end

    test "uniq duplicates only" do
      compare_bash("echo -e 'a\na\nb\nc\nc' | uniq -d")
    end

    test "uniq unique only" do
      compare_bash("echo -e 'a\na\nb\nc\nc' | uniq -u")
    end
  end
end
