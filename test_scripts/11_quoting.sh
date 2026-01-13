#!/bin/bash
# Test: Quoting behavior
# NOTE: Quoted heredoc delimiter expansion behavior differs

# Single quotes - literal
echo '1: $var is literal'

# Double quotes - allows expansion
var="world"
echo "2: hello $var"

# Escaping in double quotes
echo "3: escaped \$var"
echo "4: escaped \\"

# Empty strings
echo "5: empty single ''"
echo "6: empty double \"\""

# Quotes preserve whitespace
spaced="  spaces  "
echo "7: [$spaced]"

# Word splitting without quotes
words="a   b   c"
count=0
for w in $words; do
  count=$((count + 1))
done
echo "8: word count=$count"

# Quoted no split
count=0
for w in "$words"; do
  count=$((count + 1))
done
echo "9: quoted count=$count"

# Quote removal
result=$(echo 'hello')
echo "10: $result"

# Single quote escape pattern  
echo "11: it's quoted"

# Empty variable in quotes
empty=""
echo "12: [$empty]"

# Special characters preserved
echo "13: special: <>&|;"

# Assignment with quotes
assigned="value with spaces"
echo "14: $assigned"

# Heredoc - unquoted delimiter (expansion)
result=$(cat <<EOF
$var is expanded
EOF
)
echo "15: $result"
