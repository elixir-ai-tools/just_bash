#!/bin/bash
# Test: Special variables and positional parameters
# NOTE: shift not tested - not yet implemented

# Set positional parameters
set -- arg1 arg2 arg3

# $1, $2, $3
echo "1: $1"
echo "2: $2"  
echo "3: $3"

# $# (argument count)
echo "4: $#"

# $@ (all arguments)
echo "5: $@"

# $* (all arguments)
echo "6: $*"

# $? (exit status)
true
echo "7: $?"
false
echo "8: $?"

# $$ (process ID - just check it exists)
if [ -n "$$" ]; then
  echo "9: pid exists"
else
  echo "9: no pid"
fi

# Combining with other expansions
first="hello"
second="world"
echo "10: ${first}-${second}"

# Default values with positional
set -- only_one
echo "11: ${2:-default}"

# Length of positional
set -- "hello"
echo "12: ${#1}"
