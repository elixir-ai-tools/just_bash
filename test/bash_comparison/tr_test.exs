defmodule JustBash.BashComparison.TrTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "tr comparison" do
    test "tr single char replacement" do
      compare_bash("echo 'hello' | tr 'l' 'L'")
    end

    test "tr space to newline" do
      compare_bash("echo 'a b c' | tr ' ' '\\n'")
    end

    test "tr delete characters" do
      compare_bash("echo 'hello' | tr -d 'l'")
    end

    test "tr character range lowercase to uppercase" do
      compare_bash("echo 'hello' | tr 'a-z' 'A-Z'")
    end
  end
end
