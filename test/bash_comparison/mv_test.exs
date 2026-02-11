defmodule JustBash.BashComparison.MvTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "mv comparison" do
    test "moves a file and removes the source" do
      compare_bash(
        "D=/tmp/jb_mv_$$; rm -rf $D; mkdir $D; echo hi > $D/src; mv $D/src $D/dst; cat $D/dst; [ -f $D/src ] && echo bad || echo ok; rm -rf $D"
      )
    end

    test "moves a file into an existing directory" do
      compare_bash(
        "D=/tmp/jb_mv_$$; rm -rf $D; mkdir $D; mkdir $D/dir; echo hi > $D/src; mv $D/src $D/dir; cat $D/dir/src; rm -rf $D"
      )
    end

    test "moves a directory into an existing directory" do
      compare_bash(
        "D=/tmp/jb_mv_$$; rm -rf $D; mkdir $D; mkdir $D/srcdir; mkdir $D/dstdir; echo hi > $D/srcdir/file; mv $D/srcdir $D/dstdir; cat $D/dstdir/srcdir/file; rm -rf $D"
      )
    end

    test "mv to the same path is a no-op" do
      compare_bash(
        "D=/tmp/jb_mv_$$; rm -rf $D; mkdir $D; echo hi > $D/file; mv $D/file $D/file 2>/dev/null; echo EXIT=$?; cat $D/file; rm -rf $D"
      )
    end

    test "overwrites an existing destination file" do
      compare_bash(
        "D=/tmp/jb_mv_$$; rm -rf $D; mkdir $D; echo old > $D/dest; echo new > $D/src; mv $D/src $D/dest; cat $D/dest; rm -rf $D"
      )
    end

    test "moves a symlink without dereferencing it" do
      compare_bash(
        "D=/tmp/jb_mv_$$; rm -rf $D; mkdir $D; cd $D; echo hi > target; ln -s target link; mv link moved; readlink moved; cat moved; rm -rf $D"
      )
    end
  end
end
