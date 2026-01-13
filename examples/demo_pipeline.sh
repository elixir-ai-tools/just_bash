#!/bin/bash
# Demo: Unix pipeline combining multiple tools

echo "=== Word frequency count ==="
echo "the quick brown fox jumps over the lazy dog the fox" \
  | sed 's/ /\n/g' \
  | sort \
  | uniq -c \
  | sort -rn \
  | head -5

echo ""
echo "=== Process log lines ==="
echo -e "INFO: started\nERROR: failed\nINFO: completed\nERROR: timeout" \
  | grep "ERROR" \
  | wc -l \
  | xargs echo "Error count:"
