# Test Coverage Gaps Analysis

## Summary

Current test suite: **1224 tests, 56 properties**
Bash comparison tests: **72 commands** compared byte-for-byte

## Areas Needing More Tests

### 1. Commands Missing Bash Comparison Tests

These commands have unit tests but NO byte-for-byte comparison with real bash:

| Command | Risk Level | Notes |
|---------|------------|-------|
| `sed` | HIGH | Complex regex, only 4 patterns in compare script, none in bash_comparison_test |
| `cut` | MEDIUM | Field/character extraction edge cases |
| `sort` | MEDIUM | Numeric, reverse, unique flags |
| `uniq` | MEDIUM | Count formatting, -d/-u flags |
| `head`/`tail` | MEDIUM | Negative counts, byte mode |
| `find` | HIGH | Complex predicates, -exec |
| `date` | HIGH | Format strings differ by platform |
| `printf` | MEDIUM | More format specifiers (%x, %o, %e) |
| `base64` | LOW | Encoding edge cases |
| `diff` | HIGH | Output format compatibility |
| `comm` | MEDIUM | Column selection |
| `paste` | MEDIUM | Delimiter handling |
| `fold` | LOW | Word breaking |
| `expand` | LOW | Tab stops |
| `nl` | LOW | Numbering formats |
| `tac` | LOW | Simple reverse |

### 2. sed - Critically Under-tested

Current bash comparisons for sed: **0**
sed has complex features that need byte-for-byte testing:

```bash
# Address ranges
sed '2,4p'
sed '/start/,/end/p'

# Multiple commands  
sed -e 's/a/b/' -e 's/c/d/'

# In-place substitution edge cases
sed 's/\(foo\)/\1bar/'   # backreferences
sed 's/a/&b/'            # & replacement
sed 's/x/y/2'            # nth occurrence

# Commands
sed 'y/abc/xyz/'         # transliterate
sed 'd'                  # delete
sed 'a\text'             # append
sed 'i\text'             # insert
```

### 3. awk - Needs More Comparison Tests

Current: 5 basic tests. Missing:

```bash
# String functions
awk '{print length($0)}'
awk '{print substr($0, 2, 3)}'
awk '{print index($0, "x")}'
awk '{gsub(/a/, "b"); print}'

# Multiple patterns
awk '/foo/{print "F"} /bar/{print "B"}'

# Field assignment
awk '{$2 = "X"; print}'

# printf in awk
awk '{printf "%05d\n", NR}'

# Arrays
awk '{a[$1]++} END {for (k in a) print k, a[k]}'
```

### 4. jq - Has Comprehensive Tests but No Bash Comparison

jq_comprehensive_test.exs has 1053 lines but doesn't compare to real jq.
Should add:

```bash
echo '{"a":1}' | jq '.a'
echo '[1,2,3]' | jq '.[]'
echo '{"a":{"b":2}}' | jq '.a.b'
echo '[1,2,3]' | jq 'map(. * 2)'
echo '{}' | jq '.missing // "default"'
```

### 5. Quoting Edge Cases

Need more comparison tests for:

```bash
# Nested quotes
echo "it's \"quoted\""
echo 'it'\''s quoted'

# Dollar in various contexts
echo "$undefined"
echo "${undefined}"
echo '$literal'

# Escape sequences
echo -e '\x41'           # hex
echo -e '\101'           # octal
echo $'tab\ttab'         # $'...' syntax

# Word splitting
x="a   b"; echo $x       # vs echo "$x"
```

### 6. Redirections - Minimal Testing

Current tests: 50 lines. Need:

```bash
# Combined redirections
cmd > out.txt 2>&1
cmd &> both.txt
cmd 2>&1 | next

# Here-strings
cat <<< "hello"

# Process substitution (if supported)
diff <(cmd1) <(cmd2)

# Append
echo a >> file; echo b >> file; cat file
```

### 7. Error Messages and Exit Codes

Need byte-for-byte comparison of error outputs:

```bash
# Command not found
nonexistent_command 2>&1

# File not found
cat /nonexistent 2>&1

# Permission denied (tricky in sandbox)
# ...

# Exit codes
false; echo $?
! true; echo $?
(exit 42); echo $?
```

### 8. Special Variables

```bash
echo $#            # argument count
echo $@            # all arguments
echo $*            # all arguments as single string
echo $0            # script name
echo $1 $2 $3      # positional args
echo $-            # shell options
echo $!            # last background PID
```

### 9. Arithmetic Edge Cases

```bash
echo $((1/0))            # division by zero
echo $((-5 % 3))         # negative modulo
echo $((2**63))          # overflow
echo $((0x1F))           # hex
echo $((017))            # octal
echo $((~5))             # bitwise not
echo $((3 & 5))          # bitwise and
echo $((3 | 5))          # bitwise or
echo $((3 ^ 5))          # bitwise xor
```

### 10. Control Flow Edge Cases

```bash
# Empty loop body
for i in; do :; done

# Break/continue
for i in 1 2 3; do if [ $i -eq 2 ]; then break; fi; echo $i; done

# Nested loops with break
for i in 1 2; do for j in a b; do if [ $j = b ]; then break 2; fi; echo $i$j; done; done

# Until loop
x=0; until [ $x -ge 3 ]; do echo $x; x=$((x+1)); done

# Case with patterns
case "hello" in h*) echo H;; *o) echo O;; esac
case "test" in [tT]*) echo T;; esac
```

---

## Recommended Priority

### P0 - Critical (add immediately)
1. sed bash comparison tests
2. awk bash comparison tests  
3. jq bash comparison tests (use real jq)
4. Error message format tests

### P1 - High (add soon)
5. Quoting edge cases
6. Arithmetic edge cases
7. Redirection tests
8. sort/uniq/cut comparison tests

### P2 - Medium (add later)
9. find command tests
10. Special variables
11. Control flow edge cases
12. date format tests

---

## How to Add Bash Comparison Tests

Add to `test/bash_comparison_test.exs`:

```elixir
describe "sed comparison" do
  test "basic substitution" do
    compare_bash("echo 'hello' | sed 's/l/L/'")
  end
  
  test "global substitution" do
    compare_bash("echo 'hello' | sed 's/l/L/g'")
  end
  
  # ... more tests
end
```

For jq, need to check if jq is installed:

```elixir
@tag :jq_comparison
describe "jq comparison" do
  setup do
    case System.cmd("which", ["jq"]) do
      {_, 0} -> :ok
      _ -> :skip
    end
  end
  
  test "simple field access" do
    compare_bash("echo '{\"a\":1}' | jq '.a'")
  end
end
```
