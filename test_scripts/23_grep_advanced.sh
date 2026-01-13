#!/bin/bash
# Test: grep (comprehensive)

# Setup
printf "hello world\nHello World\nHELLO WORLD\nline with 123\ntest@email.com\nfoo bar baz\n" > /tmp/greptest.txt

# Basic patterns
echo "1: basic match"
grep "hello" /tmp/greptest.txt

echo "2: no match"
grep "xyz" /tmp/greptest.txt
echo "exit: $?"

# Case insensitive
echo "3: -i case insensitive"
grep -i "hello" /tmp/greptest.txt | wc -l | tr -d ' '

# Invert match
echo "4: -v invert"
grep -v "line" /tmp/greptest.txt | wc -l | tr -d ' '

# Count
echo "5: -c count"
grep -c "hello" /tmp/greptest.txt

# Line numbers
echo "6: -n line numbers"
grep -n "hello" /tmp/greptest.txt

# Word match
echo "7: -w word"
grep -w "foo" /tmp/greptest.txt

# Fixed string
echo "8: -F fixed"
echo "test.*pattern" | grep -F ".*"

# Extended regex
echo "9: -E extended"
grep -E "hello|HELLO" /tmp/greptest.txt | wc -l | tr -d ' '

# Anchors
echo "10: ^ start anchor"
grep "^hello" /tmp/greptest.txt

echo "11: $ end anchor"
grep "com$" /tmp/greptest.txt

# Character classes
echo "12: [0-9] digits"
grep "[0-9]" /tmp/greptest.txt | wc -l | tr -d ' '

# Special patterns
echo "13: . any char"
echo "abc" | grep "a.c"

# Quiet mode
echo "14: -q quiet"
echo "test" | grep -q "test" && echo "found"

# stdin
echo "15: stdin"
echo "hello" | grep "ell"

# Escape special chars
echo "16: escape dot"
echo "a.b" | grep 'a\.b'

# Multiple files
printf "first file\n" > /tmp/grep1.txt
printf "second file\n" > /tmp/grep2.txt

echo "17: multiple files"
grep "file" /tmp/grep1.txt /tmp/grep2.txt | wc -l | tr -d ' '

echo "18: -l list files"
grep -l "first" /tmp/grep1.txt /tmp/grep2.txt

# Cleanup
rm -f /tmp/greptest.txt /tmp/grep1.txt /tmp/grep2.txt

echo "19: done"
