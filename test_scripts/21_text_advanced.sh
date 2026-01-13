#!/bin/bash
# Test: Advanced text processing (comm, diff, paste, fold, nl)

# Setup test files
printf "apple\nbanana\ncherry\n" > /tmp/f1.txt
printf "banana\ncherry\ndate\n" > /tmp/f2.txt

# comm - compare sorted files
echo "1: comm both"
comm -12 /tmp/f1.txt /tmp/f2.txt

echo "2: comm only first"
comm -23 /tmp/f1.txt /tmp/f2.txt

echo "3: comm only second"
comm -13 /tmp/f1.txt /tmp/f2.txt

# diff
echo "4: diff"
diff /tmp/f1.txt /tmp/f2.txt > /dev/null 2>&1
echo "exit: $?"

echo "5: diff same files"
diff /tmp/f1.txt /tmp/f1.txt > /dev/null && echo "same"

# paste - merge lines
printf "1\n2\n3\n" > /tmp/p1.txt
printf "a\nb\nc\n" > /tmp/p2.txt

echo "6: paste"
paste /tmp/p1.txt /tmp/p2.txt | head -1

echo "7: paste -d delimiter"
paste -d: /tmp/p1.txt /tmp/p2.txt | head -1

echo "8: paste serial"
paste -s /tmp/p1.txt

# fold - wrap lines
echo "9: fold -w"
echo "hello world this is test" | fold -w 10 | wc -l | tr -d ' '

# nl - number lines
echo "10: nl basic"
printf "a\nb\nc\n" | nl | head -1 | awk '{print $1}'

# Edge cases
echo "11: empty file comm"
printf "" > /tmp/empty.txt
comm -12 /tmp/empty.txt /tmp/f1.txt | wc -l | tr -d ' '

echo "12: single line fold"
echo "short" | fold -w 100

# Cleanup
rm -f /tmp/f1.txt /tmp/f2.txt /tmp/p1.txt /tmp/p2.txt /tmp/empty.txt

echo "13: done"
