#!/bin/bash
# Test: sed
# NOTE: Using portable sed syntax (avoiding GNU-specific features)

# Basic substitution
echo "1: substitute first"
echo "hello world" | sed 's/world/there/'

echo "2: substitute global"
echo "aaa" | sed 's/a/b/g'

echo "3: case insensitive"
echo "Hello HELLO hello" | sed 's/hello/hi/gi'

# Delimiters
echo "4: alternate delimiter"
echo "/path/to/file" | sed 's|/path|/newpath|'

# Anchors
echo "5: start anchor"
echo "hello hello" | sed 's/^hello/hi/'

echo "6: end anchor"
echo "hello hello" | sed 's/hello$/bye/'

# Capture groups
echo "7: backreference"
echo "hello world" | sed 's/\(hello\) \(world\)/\2 \1/'

# Character classes
echo "8: digit class"
echo "abc123def" | sed 's/[0-9]*/X/'

echo "9: alpha class"
echo "abc123def" | sed 's/[a-z]*/X/'

# Delete command
echo "10: delete line"
printf "a\nb\nc\n" | sed '2d'

echo "11: delete pattern"
printf "keep\ndelete this\nkeep\n" | sed '/delete/d'

echo "12: delete range"
printf "1\n2\n3\n4\n5\n" | sed '2,4d'

# Print command
echo "13: print with -n"
printf "a\nb\nc\n" | sed -n '2p'

echo "14: print pattern"
printf "yes\nno\nyes\n" | sed -n '/yes/p'

# Line addressing
echo "15: specific line"
printf "a\nb\nc\n" | sed '2s/.*/X/'

echo "16: line range"
printf "a\nb\nc\nd\n" | sed '2,3s/.*/X/'

echo "17: last line"
printf "a\nb\nc\n" | sed '$s/.*/last/'

# Multiple commands
echo "18: multiple -e"
echo "abc" | sed -e 's/a/A/' -e 's/b/B/'

echo "19: semicolon separated"
echo "abc" | sed 's/a/A/;s/b/B/'

# Transliterate (y command)
echo "20: transliterate"
echo "hello" | sed 'y/aeiou/AEIOU/'

# Special characters in replacement
echo "21: ampersand"
echo "hello" | sed 's/hello/[&]/'

# Complex patterns
echo "22: email-like"
echo "user@domain.com" | sed 's/@.*//'

echo "23: path manipulation"
echo "/path/to/file.txt" | sed 's|.*/||'

echo "24: remove extension"
echo "file.txt" | sed 's/\.[^.]*$//'

# Empty replacement
echo "25: empty replacement"
echo "hello world" | sed 's/world//'

# Whitespace
echo "26: collapse spaces"
echo "a   b   c" | sed 's/  */ /g'

echo "27: done"
