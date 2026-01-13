#!/bin/bash
# Test: Arrays and positional parameters

# Array literal syntax
echo "1: array literal"
arr=(apple banana cherry)
echo "${arr[0]}"
echo "${arr[1]}"
echo "${arr[2]}"

# All array elements
echo "2: all elements @"
arr=(one two three)
echo "${arr[@]}"

echo "3: all elements *"
arr=(x y z)
echo "${arr[*]}"

# Array length
echo "4: array length"
arr=(a b c d e)
echo "${#arr[@]}"

# Plain var = first element
echo "5: plain var"
arr=(first second third)
echo "$arr"

# Element string length
echo "6: element length"
arr=(hello world)
echo "${#arr[0]}"

# Array with variable expansion
echo "7: array with vars"
x=foo
y=bar
arr=($x $y baz)
echo "${arr[@]}"

# Positional params
echo "8: positional params"
set -- one two three
echo "$1 $2 $3"

# All positional
echo "9: all positional @"
echo "$@"

echo "10: all positional *"
echo "$*"

# Positional count
echo "11: positional count"
echo "$#"

# Word splitting iteration
echo "12: word split iterate"
items="x y z"
for item in $items; do
  echo "$item"
done

echo "13: done"
