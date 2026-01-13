#!/bin/bash
# Demo: jq recursive operations

echo "=== Find all numbers in nested structure ==="
echo '{"a": {"b": 1, "c": {"d": 2}}, "e": 3}' | jq '[.. | numbers]'

echo ""
echo "=== Walk and transform all strings ==="
echo '{"name": "alice", "data": {"city": "nyc"}}' | jq 'walk(if type == "string" then ascii_upcase else . end)'

echo ""
echo "=== Get all leaf paths ==="
echo '{"a": {"b": 1}, "c": 2}' | jq '[paths(type != "object" and type != "array")]'
