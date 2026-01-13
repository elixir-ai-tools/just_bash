#!/bin/bash
# Test: Environment variables (env, export, unset, printenv, read)

# Basic variable
echo "1: basic var"
MY_VAR=hello
echo "$MY_VAR"

# Export
echo "2: export"
export EXPORTED=world
echo "$EXPORTED"

# Export with value
echo "3: export with value"
export NEW_EXPORT="new value"
echo "$NEW_EXPORT"

# printenv
echo "4: printenv specific"
printenv EXPORTED

# Unset
echo "5: unset"
TOUNSET=value
echo "before: $TOUNSET"
unset TOUNSET
echo "after: [$TOUNSET]"

# Variable in subshell
echo "6: subshell var"
PARENT=parent
result=$(echo "$PARENT")
echo "$result"

# Subshell doesn't affect parent
echo "7: subshell isolation"
OUTER=outer
(OUTER=modified)
echo "$OUTER"

# Export persists to subshell
echo "8: export to subshell"
export PERSIST=persisted
result=$(echo "$PERSIST")
echo "$result"

# Default env vars
echo "9: HOME exists"
test -n "$HOME" && echo "yes" || echo "no"

echo "10: PWD"
test -n "$PWD" && echo "yes" || echo "no"

# Variable expansion in assignment
echo "11: expansion in assign"
BASE=hello
DERIVED="${BASE}_world"
echo "$DERIVED"

# Append to variable
echo "12: append"
APPEND=start
APPEND="${APPEND}_end"
echo "$APPEND"

# Empty vs unset
echo "13: empty vs unset"
EMPTY=""
echo "empty: [${EMPTY:-default}]"
echo "unset: [${NOTSET:-default}]"

# Multiple export
echo "14: multi export"
export A=1 B=2 C=3
echo "$A $B $C"

# IFS
echo "15: IFS default"
words="a b c"
count=0
for w in $words; do count=$((count+1)); done
echo "$count"

# Special vars
echo "16: \$? after true"
true
echo "$?"

echo "17: \$? after false"
false
echo "$?"

echo "18: done"
