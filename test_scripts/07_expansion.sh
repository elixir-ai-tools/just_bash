#!/bin/bash
# Test: Various expansions

# Brace expansion - sequences
echo "1: brace seq"
result=$(echo {1..5})
echo "$result"

echo "2: brace alpha"
result=$(echo {a..e})
echo "$result"

# Brace expansion - lists
echo "3: brace list"
result=$(echo {a,b,c})
echo "$result"

echo "4: prefix/suffix"
result=$(echo pre{1,2}suf)
echo "$result"

echo "5: cross product"
result=$(echo {a,b}{1,2})
echo "$result"

# Command substitution
echo "6: cmd subst"
result=$(echo test)
echo "$result"

# Arithmetic expansion
echo "7: arithmetic"
echo "$((5 + 3))"

# Parameter expansion - length
var="hello"
echo "8: length"
echo "${#var}"

# Word splitting
words="one two three"
echo "9: word split count"
count=0
for w in $words; do
  count=$((count + 1))
done
echo "$count"

# Quote preservation
quoted="one   two"
echo "10: quoted"
echo "[$quoted]"

# Empty expansion
empty=""
echo "11: empty"
echo "[$empty]"

# Mixed expansions
prefix="hello"
suffix=$(echo "world")
num=$((1+1))
echo "12: mixed"
echo "${prefix}_${suffix}_${num}"
