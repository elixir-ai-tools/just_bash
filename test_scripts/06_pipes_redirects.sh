#!/bin/bash
# Test: Pipes and redirections
# NOTE: stdin redirect from file (< file) not tested - not yet implemented
# NOTE: here string (<<<) not tested - not yet implemented

# Basic pipe
result=$(echo hello world | cut -d' ' -f2)
echo "1: $result"

# Pipe to wc
result=$(printf "one\ntwo\nthree\n" | wc -l | tr -d ' ')
echo "2: $result"

# Multiple pipes
result=$(printf "c\nb\na\n" | sort | head -1)
echo "3: $result"

# Redirect stdout
echo "test content" > /tmp/jb_test1.txt
echo "4: $(cat /tmp/jb_test1.txt)"

# Append redirect
echo "line1" > /tmp/jb_test2.txt
echo "line2" >> /tmp/jb_test2.txt
result=$(cat /tmp/jb_test2.txt | wc -l | tr -d ' ')
echo "5: $result"

# Stderr redirect to /dev/null
cat /nonexistent_xyz 2>/dev/null
echo "6: exit:$?"

# Here document
result=$(cat <<EOF
heredoc line
EOF
)
echo "7: $result"

# Pipe with grep
result=$(printf "apple\nbanana\napricot\n" | grep "^a" | wc -l | tr -d ' ')
echo "8: $result"

# Tee
echo "tee test" | tee /tmp/jb_test4.txt > /dev/null
echo "9: $(cat /tmp/jb_test4.txt)"

# Pipeline exit code
true | true
echo "10: $?"

false | true
echo "11: $?"

# Cleanup
rm -f /tmp/jb_test1.txt /tmp/jb_test2.txt /tmp/jb_test4.txt 2>/dev/null
echo "12: done"
