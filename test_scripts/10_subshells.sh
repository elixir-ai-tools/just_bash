#!/bin/bash
# Test: Subshells and command grouping

# Basic subshell
result=$(echo "subshell")
echo "1: $result"

# Subshell doesn't affect parent
x=original
(x=modified)
echo "2: $x"

# Command group with braces (affects current shell)
y=original
{ y=modified; }
echo "3: $y"

# Subshell with multiple commands
line1=$(echo first)
line2=$(echo second)
echo "4: $line1 $line2"

# Variable in subshell output
val="test"
result=$(echo "val=$val")
echo "5: $result"

# Subshell exit code
(exit 5)
echo "6: $?"

# Subshell with function
subfunc() {
  echo "from function"
}
result=$(subfunc)
echo "7: $result"

# Arithmetic in subshell
result=$(echo $((5 + 3)))
echo "8: $result"

# Multiple subshells
a=$(echo first)
b=$(echo second)
echo "9: $a and $b"

# Command group output
output=$({ echo grouped; })
echo "10: $output"
