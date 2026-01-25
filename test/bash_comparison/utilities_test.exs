defmodule JustBash.BashComparison.UtilitiesTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "seq command" do
    test "seq simple range" do
      compare_bash("seq 1 5")
    end

    test "seq single number" do
      compare_bash("seq 3")
    end

    test "seq with step" do
      compare_bash("seq 1 2 10")
    end

    test "seq descending" do
      compare_bash("seq 5 -1 1")
    end

    test "seq in for loop" do
      compare_bash("for i in $(seq 1 3); do echo $i; done")
    end

    test "seq single value" do
      compare_bash("seq 1 1")
    end

    test "seq negative range" do
      compare_bash("seq -3 -1")
    end
  end

  describe "basename command" do
    test "basename simple" do
      compare_bash("basename /path/to/file.txt")
    end

    test "basename with suffix" do
      compare_bash("basename /path/to/file.txt .txt")
    end

    test "basename no path" do
      compare_bash("basename file.txt")
    end

    test "basename trailing slash" do
      compare_bash("basename /path/to/dir/")
    end

    test "basename root" do
      compare_bash("basename /")
    end

    test "basename multiple slashes" do
      compare_bash("basename /path//to///file")
    end

    test "basename suffix no match" do
      compare_bash("basename file.txt .log")
    end
  end

  describe "dirname command" do
    test "dirname simple" do
      compare_bash("dirname /path/to/file.txt")
    end

    test "dirname no path" do
      compare_bash("dirname file.txt")
    end

    test "dirname trailing slash" do
      compare_bash("dirname /path/to/dir/")
    end

    test "dirname root file" do
      compare_bash("dirname /file.txt")
    end

    test "dirname root" do
      compare_bash("dirname /")
    end

    test "dirname relative path" do
      compare_bash("dirname path/to/file")
    end

    test "dirname single component" do
      compare_bash("dirname filename")
    end
  end

  describe "tee command" do
    test "tee to file" do
      compare_bash(
        "mkdir -p /tmp/teetest; echo hello | tee /tmp/teetest/out.txt; cat /tmp/teetest/out.txt; rm -rf /tmp/teetest"
      )
    end

    test "tee passes through" do
      compare_bash("echo hello | tee /dev/null")
    end

    test "tee append mode" do
      compare_bash(
        "mkdir -p /tmp/teetest; echo first > /tmp/teetest/out.txt; echo second | tee -a /tmp/teetest/out.txt > /dev/null; cat /tmp/teetest/out.txt; rm -rf /tmp/teetest"
      )
    end
  end

  describe "xargs command" do
    test "xargs simple" do
      compare_bash("echo 'a b c' | xargs echo")
    end

    test "xargs with echo -n limit" do
      compare_bash("echo 'a b c' | xargs -n 1 echo")
    end

    test "xargs from multiple lines" do
      compare_bash("echo -e 'a\\nb\\nc' | xargs echo")
    end
  end

  describe "utilities in pipelines" do
    test "seq piped to wc" do
      compare_bash("seq 1 10 | wc -l | tr -d ' '")
    end

    test "basename in command substitution" do
      compare_bash("file=/path/to/script.sh; name=$(basename $file .sh); echo $name")
    end

    test "dirname and basename together" do
      compare_bash("path=/usr/local/bin/bash; echo $(dirname $path)/$(basename $path)")
    end
  end
end
