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

  describe "uniq edge cases" do
    test "empty input" do
      compare_bash("echo -n '' | uniq")
    end

    test "single line" do
      compare_bash("echo 'hello' | uniq")
    end

    test "no duplicates" do
      compare_bash("echo -e 'a\nb\nc' | uniq")
    end

    test "all duplicates" do
      compare_bash("echo -e 'a\na\na\na' | uniq")
    end

    test "alternating duplicates" do
      compare_bash("echo -e 'a\nb\na\nb\na' | uniq")
    end

    test "duplicates only with no duplicates" do
      compare_bash("echo -e 'a\nb\nc' | uniq -d")
    end

    test "unique only with all duplicates" do
      compare_bash("echo -e 'a\na\nb\nb' | uniq -u")
    end

    test "uniq preserves order" do
      compare_bash("echo -e 'z\nz\na\na\nm\nm' | uniq")
    end

    test "uniq with mixed consecutive and non-consecutive" do
      compare_bash("echo -e 'a\na\nb\nb\na\na' | uniq")
    end

    test "uniq combined -du flags (shows nothing)" do
      compare_bash("echo -e 'a\na\nb' | uniq -du")
    end

    test "duplicates only multiple groups" do
      compare_bash("echo -e 'a\na\na\nb\nb\nc\nc\nc\nc' | uniq -d")
    end

    test "unique only single occurrence" do
      compare_bash("echo -e 'a\nb\nb\nc' | uniq -u")
    end

    test "uniq with whitespace differences" do
      compare_bash("echo -e 'a b\na  b\na b' | uniq")
    end
  end
end
