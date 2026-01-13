#!/bin/bash
# Test: jq (comprehensive)

# Basic access
echo "1: identity"
echo '{"a":1}' | jq -c '.'

echo "2: field access"
echo '{"name":"alice","age":30}' | jq '.name'

echo "3: nested access"
echo '{"user":{"name":"bob"}}' | jq '.user.name'

echo "4: array index"
echo '[10,20,30]' | jq '.[1]'

echo "5: array slice"
echo '[1,2,3,4,5]' | jq -c '.[1:4]'

echo "6: iterate array"
echo '[1,2,3]' | jq '.[]'

# Operators
echo "7: arithmetic"
echo '5' | jq '. + 3'

echo "8: multiply"
echo '5' | jq '. * 2'

echo "9: comparison"
echo '5' | jq '. > 3'

echo "10: equality"
echo '5' | jq '. == 5'

# Builtins
echo "11: length string"
echo '"hello"' | jq 'length'

echo "12: length array"
echo '[1,2,3,4,5]' | jq 'length'

echo "13: keys"
echo '{"b":2,"a":1}' | jq -c 'keys'

echo "14: type string"
echo '"hello"' | jq 'type'

echo "15: type number"
echo '42' | jq 'type'

# Array functions
echo "16: first"
echo '[1,2,3]' | jq 'first'

echo "17: last"
echo '[1,2,3]' | jq 'last'

echo "18: reverse"
echo '[1,2,3]' | jq -c 'reverse'

echo "19: sort"
echo '[3,1,2]' | jq -c 'sort'

echo "20: unique"
echo '[1,2,1,3,2]' | jq -c 'unique'

echo "21: flatten"
echo '[[1,2],[3,[4,5]]]' | jq -c 'flatten'

echo "22: min"
echo '[5,2,8,1]' | jq 'min'

echo "23: max"
echo '[5,2,8,1]' | jq 'max'

echo "24: add"
echo '[1,2,3,4]' | jq 'add'

# Map and select
echo "25: map"
echo '[1,2,3]' | jq -c 'map(. * 2)'

echo "26: select"
echo '[1,2,3,4,5]' | jq -c '[.[] | select(. > 2)]'

# String functions
echo "27: ascii_downcase"
echo '"HELLO"' | jq 'ascii_downcase'

echo "28: ascii_upcase"
echo '"hello"' | jq 'ascii_upcase'

echo "29: split"
echo '"a,b,c"' | jq -c 'split(",")'

echo "30: join"
echo '["a","b","c"]' | jq 'join("-")'

echo "31: startswith"
echo '"hello world"' | jq 'startswith("hello")'

echo "32: endswith"
echo '"hello world"' | jq 'endswith("world")'

echo "33: contains"
echo '"hello world"' | jq 'contains("lo wo")'

echo "34: ltrimstr"
echo '"hello world"' | jq 'ltrimstr("hello ")'

echo "35: rtrimstr"
echo '"hello world"' | jq 'rtrimstr(" world")'

# Object construction
echo "36: object literal"
echo 'null' | jq -c '{a:1,b:2}'

echo "37: object from values"
echo '{"x":1,"y":2}' | jq -c '{sum: (.x + .y)}'

echo "38: array construction"
echo '{"a":1,"b":2}' | jq -c '[.a, .b]'

# Conditionals
echo "39: if-then-else"
echo '5' | jq 'if . > 3 then "big" else "small" end'

echo "40: alternative operator"
echo 'null' | jq '.x // "default"'

# Multiple outputs
echo "41: multiple expressions"
echo '{"a":1,"b":2}' | jq '.a, .b'

echo "42: range"
echo 'null' | jq -c '[range(5)]'
