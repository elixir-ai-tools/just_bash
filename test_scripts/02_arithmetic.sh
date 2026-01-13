#!/bin/bash
# Test: Arithmetic expansion

# Basic operations
echo "1: $((1 + 2))"
echo "2: $((10 - 3))"
echo "3: $((4 * 5))"
echo "4: $((20 / 4))"
echo "5: $((17 % 5))"

# Parentheses
echo "6: $(( (2 + 3) * 4 ))"

# Variables in arithmetic
a=10
b=3
echo "7: $((a + b))"
echo "8: $((a * b))"
echo "9: $((a / b))"
echo "10: $((a % b))"

# Comparison (returns 1 for true, 0 for false)
echo "11: $((5 > 3))"
echo "12: $((5 < 3))"
echo "13: $((5 == 5))"
echo "14: $((5 != 3))"
echo "15: $((5 >= 5))"
echo "16: $((5 <= 5))"

# Logical operators
echo "17: $((1 && 1))"
echo "18: $((1 && 0))"
echo "19: $((0 || 1))"
echo "20: $((0 || 0))"
echo "21: $((!0))"
echo "22: $((!1))"

# Bitwise operators
echo "23: $((5 & 3))"
echo "24: $((5 | 3))"
echo "25: $((5 ^ 3))"
echo "26: $((~0))"
echo "27: $((1 << 4))"
echo "28: $((16 >> 2))"

# Ternary operator
echo "29: $((5 > 3 ? 100 : 200))"
echo "30: $((5 < 3 ? 100 : 200))"

# Increment/decrement
x=5
echo "31: $((x++))"
echo "32: $x"
echo "33: $((++x))"
echo "34: $x"
echo "35: $((x--))"
echo "36: $x"
echo "37: $((--x))"
echo "38: $x"

# Compound assignment
y=10
echo "39: $((y += 5))"
echo "40: $y"
echo "41: $((y -= 3))"
echo "42: $y"
echo "43: $((y *= 2))"
echo "44: $y"
echo "45: $((y /= 4))"
echo "46: $y"

# Negative numbers
echo "47: $((-5 + 3))"
echo "48: $((5 + -3))"

# Hex and octal
echo "49: $((0x10))"
echo "50: $((010))"
