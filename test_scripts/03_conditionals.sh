#!/bin/bash
# Test: Conditionals (if, case, test) - bash 3.2 compatible

# Basic if
if true; then
  echo "1: true branch"
fi

if false; then
  echo "FAIL"
else
  echo "2: false branch"
fi

# if-elif-else
x=5
if [ "$x" -eq 10 ]; then
  echo "FAIL"
elif [ "$x" -eq 5 ]; then
  echo "3: elif branch"
else
  echo "FAIL"
fi

# Numeric comparisons
a=10
b=20
if [ "$a" -lt "$b" ]; then echo "4: a < b"; fi
if [ "$b" -gt "$a" ]; then echo "5: b > a"; fi
if [ "$a" -le 10 ]; then echo "6: a <= 10"; fi
if [ "$b" -ge 20 ]; then echo "7: b >= 20"; fi
if [ "$a" -eq 10 ]; then echo "8: a == 10"; fi
if [ "$a" -ne "$b" ]; then echo "9: a != b"; fi

# String comparisons
s1="hello"
s2="world"
s3="hello"
if [ "$s1" = "$s3" ]; then echo "10: s1 = s3"; fi
if [ "$s1" != "$s2" ]; then echo "11: s1 != s2"; fi
if [ -n "$s1" ]; then echo "12: s1 not empty"; fi
if [ -z "" ]; then echo "13: empty string"; fi

# Logical operators in test
if [ "$a" -lt 20 ] && [ "$a" -gt 5 ]; then
  echo "14: and condition"
fi

if [ "$a" -eq 100 ] || [ "$a" -eq 10 ]; then
  echo "15: or condition"
fi

if ! [ "$a" -eq 20 ]; then
  echo "16: negation"
fi

# case statement
fruit="apple"
case "$fruit" in
  apple)
    echo "17: matched apple"
    ;;
  banana)
    echo "FAIL"
    ;;
  *)
    echo "FAIL"
    ;;
esac

# case with patterns
val="hello123"
case "$val" in
  hello*)
    echo "18: pattern match"
    ;;
  *)
    echo "FAIL"
    ;;
esac

# case with multiple patterns
letter="b"
case "$letter" in
  a|b|c)
    echo "19: a, b, or c"
    ;;
  *)
    echo "FAIL"
    ;;
esac

# Nested if
outer=1
inner=2
if [ "$outer" -eq 1 ]; then
  if [ "$inner" -eq 2 ]; then
    echo "20: nested if"
  fi
fi

# Exit codes
true
echo "21: exit code $?"
false
echo "22: exit code $?"
