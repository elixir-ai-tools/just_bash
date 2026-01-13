#!/bin/bash
# Demo: Text processing tools

echo "=== grep with line numbers ==="
echo -e "line1\nfoo\nline3\nbar\nline5" | grep -n "foo"

echo ""
echo "=== cut columns ==="
echo -e "alice:30:NYC\nbob:25:LA" | cut -d: -f1,3

echo ""
echo "=== awk field processing ==="
echo -e "John 100\nJane 200\nBob 150" | awk '{total+=$2} END {print "Total:", total}'

echo ""
echo "=== sort and uniq ==="
echo -e "apple\nbanana\napple\ncherry\nbanana\napple" | sort | uniq -c | sort -rn
