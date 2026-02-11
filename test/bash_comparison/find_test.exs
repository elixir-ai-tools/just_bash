defmodule JustBash.BashComparison.FindTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "find basic usage" do
    test "find current directory" do
      compare_bash("""
      mkdir -p /tmp/findtest/sub
      touch /tmp/findtest/a.txt
      touch /tmp/findtest/sub/b.txt
      find /tmp/findtest -type f | sort
      """)
    end

    test "find by name pattern" do
      compare_bash("""
      mkdir -p /tmp/findtest2
      touch /tmp/findtest2/foo.txt
      touch /tmp/findtest2/bar.txt
      touch /tmp/findtest2/foo.log
      find /tmp/findtest2 -name '*.txt' | sort
      """)
    end

    test "find directories only" do
      compare_bash("""
      mkdir -p /tmp/findtest3/sub1/sub2
      touch /tmp/findtest3/file.txt
      find /tmp/findtest3 -type d | sort
      """)
    end

    test "find files only" do
      compare_bash("""
      mkdir -p /tmp/findtest4/sub
      touch /tmp/findtest4/file1.txt
      touch /tmp/findtest4/sub/file2.txt
      find /tmp/findtest4 -type f | sort
      """)
    end
  end

  describe "find depth control" do
    test "find with maxdepth 1" do
      compare_bash("""
      mkdir -p /tmp/findtest5/a/b
      touch /tmp/findtest5/top.txt
      touch /tmp/findtest5/a/mid.txt
      touch /tmp/findtest5/a/b/deep.txt
      find /tmp/findtest5 -maxdepth 1 | sort
      """)
    end

    test "find with maxdepth 2" do
      compare_bash("""
      mkdir -p /tmp/findtest6/a/b
      touch /tmp/findtest6/top.txt
      touch /tmp/findtest6/a/mid.txt
      touch /tmp/findtest6/a/b/deep.txt
      find /tmp/findtest6 -maxdepth 2 | sort
      """)
    end

    test "find with mindepth 1" do
      compare_bash("""
      mkdir -p /tmp/findtest7/sub
      touch /tmp/findtest7/file.txt
      find /tmp/findtest7 -mindepth 1 | sort
      """)
    end

    test "find with mindepth 2" do
      compare_bash("""
      mkdir -p /tmp/findtest8/a/b
      touch /tmp/findtest8/a/file.txt
      touch /tmp/findtest8/a/b/deep.txt
      find /tmp/findtest8 -mindepth 2 | sort
      """)
    end
  end

  describe "find name matching" do
    test "find with wildcard prefix" do
      compare_bash("""
      mkdir -p /tmp/findtest9
      touch /tmp/findtest9/test_file.txt
      touch /tmp/findtest9/other_file.txt
      touch /tmp/findtest9/readme.md
      find /tmp/findtest9 -name 'test_*' | sort
      """)
    end

    test "find with wildcard suffix" do
      compare_bash("""
      mkdir -p /tmp/findtest10
      touch /tmp/findtest10/file.txt
      touch /tmp/findtest10/data.txt
      touch /tmp/findtest10/config.yml
      find /tmp/findtest10 -name '*.txt' | sort
      """)
    end

    test "find case insensitive with iname" do
      compare_bash("""
      mkdir -p /tmp/findtest11
      touch /tmp/findtest11/README.md
      touch /tmp/findtest11/readme.txt
      touch /tmp/findtest11/Readme.doc
      find /tmp/findtest11 -iname 'readme*' | sort
      """)
    end

    test "find with question mark wildcard" do
      compare_bash("""
      mkdir -p /tmp/findtest12
      touch /tmp/findtest12/a1.txt
      touch /tmp/findtest12/ab.txt
      touch /tmp/findtest12/abc.txt
      find /tmp/findtest12 -name 'a?.txt' | sort
      """)
    end
  end

  describe "find edge cases" do
    test "find empty directory" do
      compare_bash("""
      mkdir -p /tmp/findtest13
      find /tmp/findtest13
      """)
    end

    test "find nonexistent path" do
      {real_out, _real_exit} = run_real_bash("find /tmp/nonexistent_dir_12345 2>&1")
      {just_out, _just_exit} = run_just_bash("find /tmp/nonexistent_dir_12345 2>&1")

      assert real_out =~ "No such file or directory"
      assert just_out =~ "No such file or directory"
    end

    test "find with print0 flag" do
      compare_bash("""
      mkdir -p /tmp/findtest14
      touch /tmp/findtest14/a.txt
      touch /tmp/findtest14/b.txt
      find /tmp/findtest14 -type f -print0 | wc -c
      """)
    end

    test "find current directory implicit" do
      compare_bash("""
      mkdir -p /tmp/findtest15
      cd /tmp/findtest15
      touch file.txt
      find . -type f
      """)
    end

    test "find multiple paths" do
      compare_bash("""
      mkdir -p /tmp/findtest16a /tmp/findtest16b
      touch /tmp/findtest16a/a.txt
      touch /tmp/findtest16b/b.txt
      find /tmp/findtest16a /tmp/findtest16b -type f | sort
      """)
    end
  end

  describe "find combined predicates" do
    test "find type and name" do
      compare_bash("""
      mkdir -p /tmp/findtest17/subdir.txt
      touch /tmp/findtest17/file.txt
      find /tmp/findtest17 -type f -name '*.txt' | sort
      """)
    end

    test "find maxdepth and type" do
      compare_bash("""
      mkdir -p /tmp/findtest18/a/b
      touch /tmp/findtest18/top.txt
      touch /tmp/findtest18/a/b/deep.txt
      find /tmp/findtest18 -maxdepth 2 -type f | sort
      """)
    end
  end
end
