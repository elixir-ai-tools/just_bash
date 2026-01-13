#!/bin/bash
# Test: Loops (for, while, until)
# NOTE: break/continue not tested - not yet implemented

# Basic for loop
echo "1: for loop"
for i in 1 2 3; do
  echo "  $i"
done

# For loop with variable expansion
items="a b c"
echo "2: for with variable"
for item in $items; do
  echo "  $item"
done

# For loop with brace expansion
echo "3: brace expansion"
for i in {1..3}; do
  echo "  $i"
done

# While loop
echo "4: while loop"
count=1
while [ "$count" -le 3 ]; do
  echo "  $count"
  count=$((count + 1))
done

# Until loop
echo "5: until loop"
count=1
until [ "$count" -gt 3 ]; do
  echo "  $count"
  count=$((count + 1))
done

# Nested loops
echo "6: nested loops"
for i in 1 2; do
  for j in a b; do
    echo "  $i$j"
  done
done

# Loop accumulator
echo "7: accumulator"
sum=0
for i in 1 2 3 4 5; do
  sum=$((sum + i))
done
echo "  sum=$sum"
