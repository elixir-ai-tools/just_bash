#!/bin/bash
# Demo: jq CSV output

echo "=== JSON to CSV ==="
echo '[
  {"name": "Alice", "age": 30, "city": "NYC"},
  {"name": "Bob", "age": 25, "city": "LA"},
  {"name": "Carol", "age": 35, "city": "Chicago"}
]' | jq -r '["name", "age", "city"], (.[] | [.name, .age, .city]) | @csv'
