defmodule JustBash.BashComparison.ParameterExpansionTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "basic parameter expansion" do
    test "simple variable" do
      compare_bash("x=hello; echo $x")
    end

    test "braced variable" do
      compare_bash("x=hello; echo ${x}")
    end

    test "unset variable is empty" do
      compare_bash("echo [${x}]")
    end
  end

  describe "default value ${:-}" do
    test "default value unset" do
      compare_bash("echo ${x:-default}")
    end

    test "default value set" do
      compare_bash("x=value; echo ${x:-default}")
    end

    test "default value empty with colon" do
      compare_bash("x=; echo ${x:-default}")
    end

    test "default value empty without colon" do
      compare_bash("x=; echo ${x-default}")
    end

    test "nested default" do
      compare_bash("echo ${x:-${y:-nested}}")
    end
  end

  describe "assign default ${:=}" do
    test "assign default when unset" do
      compare_bash("echo ${x:=assigned}; echo $x")
    end

    test "assign default when set" do
      compare_bash("x=existing; echo ${x:=assigned}; echo $x")
    end

    test "assign default when empty" do
      compare_bash("x=; echo ${x:=assigned}; echo $x")
    end
  end

  describe "alternative value ${:+}" do
    test "alternative when set" do
      compare_bash("x=hello; echo ${x:+world}")
    end

    test "alternative when unset" do
      compare_bash("echo ${x:+world}")
    end

    test "alternative when empty with colon" do
      compare_bash("x=; echo ${x:+world}")
    end

    test "nested alternative" do
      compare_bash("x=hello; echo ${x:+${x}world}")
    end
  end

  describe "length ${#}" do
    test "string length" do
      compare_bash("x=hello; echo ${#x}")
    end

    test "empty string length" do
      compare_bash("x=; echo ${#x}")
    end

    test "unset variable length" do
      compare_bash("echo ${#x}")
    end
  end

  describe "substring ${:offset:length}" do
    test "substring with offset and length" do
      compare_bash("x=hello; echo ${x:1:3}")
    end

    test "substring offset only" do
      compare_bash("x=hello; echo ${x:2}")
    end

    test "substring from start" do
      compare_bash("x=hello; echo ${x:0:2}")
    end

    test "negative offset" do
      compare_bash("x=hello; echo ${x: -2}")
    end
  end

  describe "pattern removal" do
    test "suffix removal shortest" do
      compare_bash("x=file.txt; echo ${x%.txt}")
    end

    test "suffix removal longest" do
      compare_bash("x=file.tar.gz; echo ${x%%.*}")
    end

    test "prefix removal shortest" do
      compare_bash("x=/path/to/file; echo ${x#*/}")
    end

    test "prefix removal longest" do
      compare_bash("x=/path/to/file; echo ${x##*/}")
    end

    test "no match suffix" do
      compare_bash("x=hello; echo ${x%.xyz}")
    end

    test "no match prefix" do
      compare_bash("x=hello; echo ${x#xyz}")
    end
  end

  describe "pattern replacement" do
    test "replace first occurrence" do
      compare_bash("x=hello; echo ${x/l/L}")
    end

    test "replace all occurrences" do
      compare_bash("x=hello; echo ${x//l/L}")
    end

    test "replace at start" do
      compare_bash("x=hello; echo ${x/#h/H}")
    end

    test "replace at end" do
      compare_bash("x=hello; echo ${x/%o/O}")
    end

    test "delete pattern" do
      compare_bash("x=hello; echo ${x/l/}")
    end
  end

  describe "indirection ${!}" do
    test "indirect variable reference" do
      compare_bash("x=y; y=value; echo ${!x}")
    end

    test "indirect unset" do
      compare_bash("x=y; echo ${!x}")
    end
  end

  # Note: ${x^^} and ${x,,} are bash 4+ features
  # macOS ships with bash 3.2, so we skip comparison
  describe "case modification" do
    @tag :skip
    test "uppercase all" do
      compare_bash("x=hello; echo ${x^^}")
    end

    @tag :skip
    test "lowercase all" do
      compare_bash("x=HELLO; echo ${x,,}")
    end
  end
end
