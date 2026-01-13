#!/bin/bash
# Test: File operations (ls, cp, mv, rm, mkdir, touch, ln, find)

# Setup
mkdir -p /tmp/testdir/subdir
echo "content1" > /tmp/testdir/file1.txt
echo "content2" > /tmp/testdir/file2.txt

# mkdir
echo "1: mkdir"
mkdir /tmp/newdir
test -d /tmp/newdir && echo "  created"

echo "2: mkdir -p"
mkdir -p /tmp/deep/nested/path
test -d /tmp/deep/nested/path && echo "  created nested"

# touch
echo "3: touch new file"
touch /tmp/testdir/newfile.txt
test -f /tmp/testdir/newfile.txt && echo "  created"

# ls basic
echo "4: ls"
ls /tmp/testdir | grep "\.txt" | wc -l | tr -d ' '

echo "5: ls sorted"
ls /tmp/testdir | sort | head -2

# cp
echo "6: cp file"
cp /tmp/testdir/file1.txt /tmp/testdir/file1_copy.txt
cat /tmp/testdir/file1_copy.txt

# mv
echo "7: mv rename"
echo "moveme" > /tmp/testdir/tomove.txt
mv /tmp/testdir/tomove.txt /tmp/testdir/moved.txt
test -f /tmp/testdir/moved.txt && echo "  renamed"
test ! -f /tmp/testdir/tomove.txt && echo "  original gone"

# rm
echo "8: rm file"
echo "deleteme" > /tmp/testdir/todelete.txt
rm /tmp/testdir/todelete.txt
test ! -f /tmp/testdir/todelete.txt && echo "  deleted"

echo "9: rm -r directory"
mkdir -p /tmp/testdir/toremove/nested
rm -r /tmp/testdir/toremove
test ! -d /tmp/testdir/toremove && echo "  deleted dir"

# ln -s symlink
echo "10: ln -s symlink"
ln -s /tmp/testdir/file1.txt /tmp/testdir/link1
cat /tmp/testdir/link1

# find
echo "11: find by name"
find /tmp/testdir -name "*.txt" 2>/dev/null | wc -l | tr -d ' '

# cat
echo "12: cat"
cat /tmp/testdir/file1.txt

echo "13: cat multiple"
cat /tmp/testdir/file1.txt /tmp/testdir/file2.txt | wc -l | tr -d ' '

# pwd and cd
echo "14: pwd and cd"
cd /tmp/testdir
basename "$(pwd)"

# test operators
echo "15: test -f"
test -f /tmp/testdir/file1.txt && echo "  is file"

echo "16: test -d"
test -d /tmp/testdir/subdir && echo "  is dir"

echo "17: test -e"
test -e /tmp/testdir/file1.txt && echo "  exists"

echo "18: test ! -e"
test ! -e /tmp/testdir/nonexistent && echo "  not exists"

# Cleanup
rm -rf /tmp/testdir /tmp/newdir /tmp/deep 2>/dev/null
echo "19: done"
