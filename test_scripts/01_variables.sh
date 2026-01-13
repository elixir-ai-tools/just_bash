#!/bin/bash
# Test: Variable assignment and expansion

# Basic assignment
x=hello
echo "1: $x"

# Assignment with spaces in value
y="hello world"
echo "2: $y"

# Variable in variable
z="value is $x"
echo "3: $z"

# Unset variable (empty)
echo "4: [$unset_var]"

# Default value ${var:-default}
echo "5: ${unset_var:-default}"
echo "6: ${x:-default}"

# Assign default ${var:=default}
echo "7: ${new_var:=assigned}"
echo "8: $new_var"

# Use alternate ${var:+alternate}
echo "9: ${x:+alternate}"
echo "10: ${unset_var:+alternate}"

# String length
str="hello"
echo "11: ${#str}"

# Substring ${var:offset:length}
echo "12: ${str:1:3}"
echo "13: ${str:2}"

# Pattern removal
path="/home/user/file.txt"
echo "14: ${path#*/}"
echo "15: ${path##*/}"
echo "16: ${path%/*}"
echo "17: ${path%%/*}"

# Pattern substitution
text="hello hello world"
echo "18: ${text/hello/hi}"
echo "19: ${text//hello/hi}"

# Numeric variable
num=42
echo "20: $num"

# Multiple assignments
a=1 b=2 c=3
echo "21: $a $b $c"

# Empty string assignment
empty=""
echo "22: [$empty]"

# Variable with underscore
my_var="underscore"
echo "23: $my_var"

# Reassignment
base="original"
base="modified"
echo "24: $base"
