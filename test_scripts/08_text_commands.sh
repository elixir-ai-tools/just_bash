#!/bin/bash
# Test: Text processing commands - avoiding nested quotes

# echo basic
echo "1: basic"

# printf
result=$(printf "%s\n" "printf test")
echo "2: $result"
result=$(printf "%d\n" 42)
echo "3: $result"
result=$(printf "%05d\n" 7)
echo "4: $result"

# cat
result=$(printf "a\nb\n" | cat | head -1)
echo "5: $result"

# head
result=$(printf "1\n2\n3\n4\n5\n" | head -2 | tail -1)
echo "6: $result"

# tail  
result=$(printf "1\n2\n3\n4\n5\n" | tail -2 | head -1)
echo "7: $result"

# cut
result=$(echo "a:b:c" | cut -d: -f2)
echo "8: $result"
result=$(echo "hello" | cut -c1-3)
echo "9: $result"

# tr
result=$(echo "hello" | tr 'a-z' 'A-Z')
echo "10: $result"
result=$(echo "hello" | tr -d 'l')
echo "11: $result"

# sort
result=$(printf "c\na\nb\n" | sort | head -1)
echo "12: $result"
result=$(printf "10\n2\n1\n" | sort -n | head -1)
echo "13: $result"

# uniq
result=$(printf "a\na\nb\n" | uniq | wc -l | tr -d ' ')
echo "14: $result"

# wc
result=$(printf "a\nb\nc\n" | wc -l | tr -d ' ')
echo "15: $result"
result=$(echo "hello world" | wc -w | tr -d ' ')
echo "16: $result"

# grep
result=$(printf "apple\nbanana\n" | grep "apple")
echo "17: $result"
result=$(printf "Apple\napple\n" | grep -i "APPLE" | wc -l | tr -d ' ')
echo "18: $result"
result=$(printf "yes\nno\n" | grep -v "no")
echo "19: $result"

# sed
result=$(echo "hello world" | sed 's/world/there/')
echo "20: $result"
result=$(echo "aaa" | sed 's/a/b/g')
echo "21: $result"

# rev
result=$(echo "hello" | rev)
echo "22: $result"

# seq
result=$(seq 3 | tail -1)
echo "23: $result"
result=$(seq 2 5 | head -1)
echo "24: $result"

# basename/dirname
result=$(basename /path/to/file.txt)
echo "25: $result"
result=$(dirname /path/to/file.txt)
echo "26: $result"
