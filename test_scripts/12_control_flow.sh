#!/bin/bash
# Test: Control flow operators

# && (and)
echo "1: && test"
true && echo "  true && works"

false && echo "FAIL"
echo "2: false && skipped"

# || (or)  
echo "3: || test"
false || echo "  false || works"

true || echo "FAIL"
echo "4: true || skipped"

# Chained && 
echo "5: chained &&"
true && true && echo "  both true"

true && false && echo "FAIL"
echo "6: second false"

# Chained ||
echo "7: chained ||"
false || false || echo "  both false triggers"

# Mixed && and ||
echo "8: mixed"
true && false || echo "  fallback works"

# Command chains with ;
echo "9: semicolon"
echo "  first"; echo "  second"

# Exit codes propagate
true && false
echo "10: exit=$?"

false || true
echo "11: exit=$?"

# Short-circuit with side effects
x=0
false && x=1
echo "12: x=$x after false &&"

true || x=2
echo "13: x=$x after true ||"

# Negation with !
echo "14: negation"
! false && echo "  ! false is true"
! true || echo "  ! true is false"

# Pipeline exit status
echo "test" | cat > /dev/null && echo "15: pipeline success"

# Subshell exit with &&
(exit 0) && echo "16: subshell 0"
(exit 1) || echo "17: subshell 1"

# Assignment success
x=1 && echo "18: assignment succeeded"

# Multiple commands in branch
true && { echo "19: branch1"; echo "  branch2"; }
