#!/bin/bash
# Test: awk
# NOTE: Some awk arithmetic expressions have issues

# Basic field printing
echo "1: print field"
echo "one two three" | awk '{print $2}'

echo "2: print multiple fields"
echo "a b c d" | awk '{print $1, $3}'

echo "3: print all"
echo "a b c" | awk '{print $0}'

# Field separator
echo "4: -F delimiter"
echo "a:b:c" | awk -F: '{print $2}'

# Built-in variables
echo "5: NR line number"
printf "a\nb\nc\n" | awk '{print NR, $0}'

echo "6: NF field count"
echo "one two three four" | awk '{print NF}'

# Patterns
echo "7: pattern match"
printf "apple\nbanana\napricot\n" | awk '/^a/'

# BEGIN and END
echo "8: BEGIN"
echo "data" | awk 'BEGIN {print "header"} {print $0}'

echo "9: END"
printf "1\n2\n3\n" | awk 'END {print "done"}'

# String functions
echo "10: length"
echo "hello" | awk '{print length($0)}'

echo "11: substr"
echo "hello world" | awk '{print substr($0, 1, 5)}'

echo "12: tolower"
echo "HELLO" | awk '{print tolower($0)}'

echo "13: toupper"
echo "hello" | awk '{print toupper($0)}'

echo "14: gsub"
echo "hello hello" | awk '{gsub(/hello/, "hi"); print}'

echo "15: sub"
echo "hello hello" | awk '{sub(/hello/, "hi"); print}'

# Variables
echo "16: -v variable"
echo "test" | awk -v x=5 '{print x}'

# Conditionals
echo "17: if"
echo "5" | awk '{if ($1 > 3) print "big"; else print "small"}'

echo "18: ternary"
echo "5" | awk '{print ($1 > 3) ? "big" : "small"}'

# printf
echo "19: printf"
echo "42" | awk '{printf "%05d\n", $1}'

# OFS
echo "20: OFS"
echo "a b c" | awk 'BEGIN {OFS=":"} {print $1,$2,$3}'

echo "21: done"
