#!/bin/bash
# Test: Utilities (hostname, which, xargs, tee, md5sum, base64)

# hostname
echo "1: hostname"
result=$(hostname)
test -n "$result" && echo "has hostname" || echo "empty"

# which
echo "2: which"
which echo > /dev/null && echo "found echo"

echo "3: which not found"
which nonexistent_command_xyz 2>/dev/null
echo "exit: $?"

# xargs
echo "4: xargs basic"
echo "a b c" | xargs echo "items:"

echo "5: xargs -n"
echo "a b c d" | xargs -n 2 echo | wc -l | tr -d ' '

# tee
echo "6: tee"
echo "tee test" | tee /tmp/tee_out.txt > /dev/null
cat /tmp/tee_out.txt
rm /tmp/tee_out.txt

echo "7: tee to /dev/null"
echo "test" | tee /dev/null

# md5sum
echo "8: md5sum"
echo -n "hello" | md5sum | cut -d' ' -f1

# base64
echo "9: base64 encode"
echo -n "hello" | base64

echo "10: base64 decode"
echo "aGVsbG8=" | base64 -d

echo "11: base64 roundtrip"
original="test123"
encoded=$(echo -n "$original" | base64)
decoded=$(echo "$encoded" | base64 -d)
test "$original" = "$decoded" && echo "match"

# seq variations
echo "12: seq"
seq 3

echo "13: seq range"
seq 2 4

echo "14: seq increment"
seq 1 2 7

# Combinations
echo "15: pipeline with tee"
echo "pipeline" | tee /dev/null | tr 'a-z' 'A-Z'

echo "16: done"
