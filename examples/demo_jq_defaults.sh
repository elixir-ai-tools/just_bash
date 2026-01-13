#!/bin/bash
# Demo: jq default values with //

echo "=== Default for missing key ==="
echo '{"a": 1}' | jq '.b // "not found"'

echo ""
echo "=== Default for null ==="
echo '{"a": null}' | jq '.a // "was null"'

echo ""
echo "=== Chain defaults ==="
echo '{}' | jq '.x // .y // .z // "all missing"'

echo ""
echo "=== With array access ==="
echo '{"items": []}' | jq '.items[0] // "empty array"'
