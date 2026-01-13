#!/bin/bash
# Demo: jq object transformation

echo "=== to_entries / from_entries ==="
echo '{"a": 1, "b": 2, "c": 3}' | jq 'to_entries | map({key: .key, value: (.value * 10)}) | from_entries'

echo ""
echo "=== with_entries ==="
echo '{"x": 1, "y": 2}' | jq 'with_entries({key: ("prefix_" + .key), value: .value})'

echo ""
echo "=== Restructure data ==="
echo '{"first": "John", "last": "Doe", "age": 30}' | jq '{fullName: "\(.first) \(.last)", age: .age}'
