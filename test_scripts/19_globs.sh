#!/bin/bash
# Test: Glob patterns and pathname expansion

# Setup test files
mkdir -p /tmp/globtest
echo "a" > /tmp/globtest/file1.txt
echo "b" > /tmp/globtest/file2.txt
echo "c" > /tmp/globtest/file3.log
echo "d" > /tmp/globtest/data.csv

cd /tmp/globtest

# Basic * glob
echo "1: star glob"
ls *.txt 2>/dev/null | wc -l | tr -d ' '

echo "2: star prefix"
ls file* 2>/dev/null | wc -l | tr -d ' '

# ? single char
echo "3: question mark"
ls file?.txt 2>/dev/null | wc -l | tr -d ' '

# Multiple patterns
echo "4: multiple globs"
ls *.txt *.log 2>/dev/null | wc -l | tr -d ' '

# No match behavior
echo "5: no match"
ls *.xyz 2>/dev/null
echo "exit: $?"

# Glob with path
echo "6: absolute path glob"
ls /tmp/globtest/*.txt 2>/dev/null | wc -l | tr -d ' '

# Quoted glob (literal)
echo "7: quoted glob literal"
echo "*.txt"

# Extension extraction
echo "8: extension pattern"
for f in *.txt; do
  basename "$f" .txt
done | head -1

# Multiple extensions
echo "9: multi extension"
ls *.txt *.csv 2>/dev/null | wc -l | tr -d ' '

# Cleanup
cd /
rm -rf /tmp/globtest
echo "10: done"
