#!/bin/bash
# Test: Advanced shell features

# Command substitution
echo "1: command substitution"
result=$(echo hello)
echo "$result"

echo "2: nested substitution"
result=$(echo $(echo nested))
echo "$result"

# Arithmetic
echo "3: arithmetic expansion"
echo $((5 + 3))

echo "4: arithmetic with variable"
x=5
echo $((x * 2))

# Brace expansion
echo "5: brace list"
echo {a,b,c}

echo "6: brace sequence"
for i in {1..5}; do echo -n "$i "; done
echo ""

echo "7: brace alpha"
for i in {a..e}; do echo -n "$i "; done
echo ""

# Parameter expansion
var="hello world"

echo "8: length"
echo ${#var}

echo "9: substring"
echo ${var:0:5}

echo "10: offset"
echo ${var:6}

path="/a/b/c/file.txt"
echo "11: prefix removal"
echo ${path#*/}

echo "12: greedy prefix"
echo ${path##*/}

echo "13: suffix removal"
echo ${path%/*}

echo "14: replace"
echo ${var/world/there}

echo "15: replace all"
text="aaa"
echo ${text//a/b}

# Default values
echo "16: default value"
echo ${unset:-default}

echo "17: alternate value"
set_var="value"
echo ${set_var:+alternate}

# Conditional execution
echo "18: and chain"
true && echo "yes"

echo "19: or chain"
false || echo "fallback"

echo "20: mixed"
false && echo "skip" || echo "executed"

# Grouping
echo "21: subshell"
result=$(echo "from subshell")
echo "$result"

echo "22: brace group"
{ echo "grouped"; }

# Test expressions
echo "23: numeric test"
[ 5 -gt 3 ] && echo "greater"

echo "24: string test"
[ "a" = "a" ] && echo "equal"

echo "25: empty test"
[ -z "" ] && echo "empty"

echo "26: non-empty test"
[ -n "x" ] && echo "non-empty"

echo "27: done"
