#!/bin/bash
# Demo: jq reduce - aggregating data

echo "=== Sum with reduce ==="
echo '[1, 2, 3, 4, 5]' | jq 'reduce .[] as $x (0; . + $x)'

echo ""
echo "=== Build object with reduce ==="
echo '[{"k": "a", "v": 1}, {"k": "b", "v": 2}]' | jq 'reduce .[] as $item ({}; .[$item.k] = $item.v)'

echo ""
echo "=== Running total ==="
echo '[10, 20, 30]' | jq '[foreach .[] as $x (0; . + $x)]'
