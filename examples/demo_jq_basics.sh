#!/bin/bash
# Demo: jq basics - filtering and transforming JSON

echo '{"users": [{"name": "alice", "age": 30}, {"name": "bob", "age": 25}]}' > /tmp/data.json

echo "=== Get all user names ==="
jq '.users[].name' /tmp/data.json

echo ""
echo "=== Users over 26 ==="
jq '.users[] | select(.age > 26)' /tmp/data.json

echo ""
echo "=== Average age ==="
jq '.users | map(.age) | add / length' /tmp/data.json
