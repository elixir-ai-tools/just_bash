defmodule JustBash.BashComparison.AwkTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "awk comparison" do
    test "awk print field" do
      compare_bash("echo 'a b c' | awk '{print $2}'")
    end

    test "awk with field separator" do
      compare_bash("echo 'a,b,c' | awk -F, '{print $2}'")
    end

    test "awk sum in END block" do
      compare_bash("echo -e '1\\n2\\n3' | awk '{s+=$1} END {print s}'")
    end

    test "awk NR line number" do
      compare_bash("echo -e 'a\\nb' | awk '{print NR, $0}'")
    end

    test "awk NF field count" do
      compare_bash("echo 'a b c d' | awk '{print NF}'")
    end
  end
end
