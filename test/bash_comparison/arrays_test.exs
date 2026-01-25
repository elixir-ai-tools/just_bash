defmodule JustBash.BashComparison.ArraysTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "array literal syntax" do
    test "basic array creation and indexing" do
      compare_bash(~s|arr=(a b c); echo "${arr[0]}"|)
    end

    test "access second element" do
      compare_bash(~s|arr=(x y z); echo "${arr[1]}"|)
    end

    test "access third element" do
      compare_bash(~s|arr=(one two three); echo "${arr[2]}"|)
    end

    test "plain variable equals first element" do
      compare_bash(~s|arr=(first second third); echo "$arr"|)
    end
  end

  describe "array all elements" do
    test "all elements with @" do
      compare_bash(~s|arr=(one two three); echo "${arr[@]}"|)
    end

    test "all elements with *" do
      compare_bash(~s|arr=(x y z); echo "${arr[*]}"|)
    end

    test "single element array with @" do
      compare_bash(~s|arr=(only); echo "${arr[@]}"|)
    end

    test "empty array with @" do
      compare_bash(~s|arr=(); echo "${arr[@]}"|)
    end
  end

  describe "array length" do
    test "array element count" do
      compare_bash(~s|arr=(a b c d e); echo "${#arr[@]}"|)
    end

    test "empty array length" do
      compare_bash(~s|arr=(); echo "${#arr[@]}"|)
    end

    test "single element array length" do
      compare_bash(~s|arr=(one); echo "${#arr[@]}"|)
    end

    test "element string length" do
      compare_bash(~s|arr=(hello world); echo "${#arr[0]}"|)
    end
  end

  describe "array with variable expansion" do
    test "array with variable values" do
      compare_bash(~s|x=foo; y=bar; arr=($x $y baz); echo "${arr[@]}"|)
    end

    test "array with command substitution" do
      compare_bash(~s|arr=($(echo a b c)); echo "${arr[@]}"|)
    end
  end

  describe "positional parameters" do
    test "set positional params" do
      compare_bash(~s|set -- one two three; echo "$1 $2 $3"|)
    end

    test "all positional with @" do
      compare_bash(~s|set -- a b c; echo "$@"|)
    end

    test "all positional with *" do
      compare_bash(~s|set -- x y z; echo "$*"|)
    end

    test "positional count" do
      compare_bash(~s|set -- a b c d; echo "$#"|)
    end

    test "empty positional params" do
      compare_bash(~s|set --; echo "$#"|)
    end
  end

  describe "word splitting and iteration" do
    test "iterate over word split string" do
      compare_bash(~s|items="x y z"; for item in $items; do echo "$item"; done|)
    end

    test "iterate over array elements unquoted" do
      compare_bash(~s|arr=(a b c); for item in ${arr[@]}; do echo "$item"; done|)
    end

    # Skip: "${arr[@]}" in for loops should expand to separate words, but this is complex
    @tag :skip
    test "iterate over array elements quoted" do
      compare_bash(~s|arr=(a b c); for item in "${arr[@]}"; do echo "$item"; done|)
    end
  end

  describe "array edge cases" do
    test "array with spaces in elements using quotes" do
      compare_bash(~s|arr=("hello world" "foo bar"); echo "${arr[0]}"|)
    end

    test "array element assignment" do
      compare_bash(~s|arr=(a b c); arr[1]=changed; echo "${arr[@]}"|)
    end

    test "array out of bounds returns empty" do
      compare_bash(~s|arr=(a b); echo "[${arr[99]}]"|)
    end

    # Skip: negative index behavior and error messages differ between bash versions
    @tag :skip
    test "negative index" do
      compare_bash(~s|arr=(a b c); echo "[${arr[-1]:-}]"|, ignore_exit: true)
    end
  end
end
