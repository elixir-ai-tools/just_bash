#!/bin/bash
# Demo: jq string operations

echo "=== String interpolation ==="
echo '{"name": "world", "count": 42}' | jq -r '"Hello, \(.name)! Count: \(.count)"'

echo ""
echo "=== Regex test ==="
echo '["foo@bar.com", "invalid", "test@example.org"]' | jq '.[] | select(test("@.*\\."))' 

echo ""
echo "=== gsub replacement ==="
echo '"hello-world-test"' | jq 'gsub("-"; "_")'

echo ""
echo "=== Split and join ==="
echo '"a,b,c,d"' | jq 'split(",") | reverse | join("-")'
