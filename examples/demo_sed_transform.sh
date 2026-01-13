#!/bin/bash
# Demo: sed text transformation

echo "=== Basic substitution ==="
echo "hello world" | sed 's/world/universe/'

echo ""
echo "=== Global replace ==="
echo "abracadabra" | sed 's/a/A/g'

echo ""
echo "=== Translate characters ==="
echo "hello" | sed 'y/aeiou/AEIOU/'

echo ""
echo "=== Delete lines matching pattern ==="
echo -e "keep this\ndelete me\nkeep this too" | sed '/delete/d'

echo ""
echo "=== Insert and append ==="
echo -e "line1\nline2\nline3" | sed '2i\--- inserted ---'
