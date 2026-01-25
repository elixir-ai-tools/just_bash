defmodule JustBash.BashComparison.GlobsTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "star glob pattern" do
    test "star matches all files" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/a.txt /tmp/gt/b.txt; cd /tmp/gt; echo *.txt; rm -rf /tmp/gt|)
    end

    test "star with prefix" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/file1 /tmp/gt/file2 /tmp/gt/other; cd /tmp/gt; echo file*; rm -rf /tmp/gt|)
    end

    test "star with suffix" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/test.log /tmp/gt/app.log; cd /tmp/gt; echo *.log; rm -rf /tmp/gt|)
    end

    test "star no match returns literal" do
      compare_bash(~s|mkdir -p /tmp/gt; cd /tmp/gt; echo *.xyz; rm -rf /tmp/gt|)
    end

    test "star in for loop" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/a /tmp/gt/b; cd /tmp/gt; for f in *; do echo "$f"; done; rm -rf /tmp/gt|)
    end
  end

  describe "question mark pattern" do
    test "question mark single char" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/a1 /tmp/gt/a2 /tmp/gt/a12; cd /tmp/gt; echo a?; rm -rf /tmp/gt|)
    end

    test "question mark in middle" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/cat /tmp/gt/cot /tmp/gt/cut; cd /tmp/gt; echo c?t; rm -rf /tmp/gt|)
    end

    test "multiple question marks" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/ab /tmp/gt/abc /tmp/gt/abcd; cd /tmp/gt; echo a??; rm -rf /tmp/gt|)
    end
  end

  describe "glob quoting" do
    test "quoted glob is literal" do
      compare_bash(~s|echo "*.txt"|)
    end

    test "single quoted glob is literal" do
      compare_bash(~s|echo '*.txt'|)
    end

    test "escaped star is literal" do
      compare_bash(~s|echo \\*.txt|)
    end
  end

  describe "glob with paths" do
    test "absolute path glob" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/x.txt; echo /tmp/gt/*.txt; rm -rf /tmp/gt|)
    end

    test "relative path glob" do
      compare_bash(~s|mkdir -p /tmp/gt/sub; touch /tmp/gt/sub/a; cd /tmp/gt; echo sub/*; rm -rf /tmp/gt|)
    end
  end

  describe "glob expansion in commands" do
    test "glob in ls" do
      compare_bash(~s{mkdir -p /tmp/gt; touch /tmp/gt/a.txt /tmp/gt/b.txt; ls /tmp/gt/*.txt | wc -l | tr -d ' '; rm -rf /tmp/gt})
    end

    test "glob in cat" do
      compare_bash(~s{mkdir -p /tmp/gt; echo "a" > /tmp/gt/1.txt; echo "b" > /tmp/gt/2.txt; cat /tmp/gt/*.txt; rm -rf /tmp/gt})
    end

    test "glob count with wc" do
      compare_bash(~s{mkdir -p /tmp/gt; touch /tmp/gt/a /tmp/gt/b /tmp/gt/c; cd /tmp/gt; echo * | wc -w | tr -d ' '; rm -rf /tmp/gt})
    end
  end

  describe "glob edge cases" do
    test "empty directory" do
      compare_bash(~s|mkdir -p /tmp/gt; cd /tmp/gt; echo *; rm -rf /tmp/gt|)
    end

    test "dot files not matched by star" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/.hidden /tmp/gt/visible; cd /tmp/gt; echo *; rm -rf /tmp/gt|)
    end

    test "multiple patterns" do
      compare_bash(~s|mkdir -p /tmp/gt; touch /tmp/gt/a.txt /tmp/gt/b.log; cd /tmp/gt; echo *.txt *.log; rm -rf /tmp/gt|)
    end
  end
end
