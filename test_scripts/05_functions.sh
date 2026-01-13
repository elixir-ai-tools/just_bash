#!/bin/bash
# Test: Functions
# NOTE: return builtin not tested - not yet implemented

# Basic function
greet() {
  echo "hello"
}
echo "1: $(greet)"

# Function with arguments
add() {
  local a=$1
  local b=$2
  echo $((a + b))
}
echo "2: $(add 3 5)"

# Function with local variable
counter() {
  local count=0
  count=$((count + 1))
  echo $count
}
echo "3: $(counter)"

# Function output capture
get_value() {
  echo "result"
}
captured=$(get_value)
echo "4: $captured"

# Function keyword syntax
function named_func {
  echo "named function"
}
echo "5: $(named_func)"

# Function overwrite
dupe() {
  echo "first"
}
dupe() {
  echo "second"
}
echo "6: $(dupe)"

# Default parameter pattern
with_default() {
  local val="${1:-default}"
  echo "$val"
}
echo "7: $(with_default)"
echo "8: $(with_default custom)"

# Function with multiple outputs
multi_output() {
  echo "line1"
  echo "line2"
}
echo "9: multi"
multi_output
