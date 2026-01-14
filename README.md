<p align="center">
  <h1 align="center">JustBash</h1>
  <p align="center">
    A sandboxed bash interpreter with virtual filesystem, written in pure Elixir.
    <br />
    <strong>70+ commands | Full shell syntax | Data pipelines | Zero system access</strong>
  </p>
</p>

<p align="center">
  <a href="https://github.com/ivarvong/just_bash/actions/workflows/ci.yml"><img src="https://github.com/ivarvong/just_bash/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/hexpm/l/just_bash.svg" alt="License"></a>
</p>

> **Why this exists**: We were curious what an Elixir version of [just-bash](https://github.com/vercel-labs/just-bash) would look like. The original is a fantastic TypeScript project by Vercel Labs. This port was created as an experiment using [OpenCode](https://opencode.ai) with Claude Opus 4.5—the entire codebase (parser, interpreter, 70+ commands, 1300+ tests) was generated through conversational prompting.

---

## What is this?

JustBash executes bash scripts entirely in memory. No filesystem access. No network by default. No process spawning. Perfect for:

- **AI agents** that need safe bash execution
- **Testing** bash scripts without side effects  
- **Sandboxed environments** where system access is prohibited
- **Educational tools** for learning bash

```elixir
bash = JustBash.new()
{result, _} = JustBash.exec(bash, "echo 'Hello from the sandbox!'")
result.stdout  #=> "Hello from the sandbox!\n"
```

---

## Features at a Glance

| Category | Capabilities |
|----------|-------------|
| **Commands** | 60+ built-in commands including `grep`, `sed`, `awk`, `jq`, `curl`, `sqlite3` |
| **Shell Syntax** | Pipes, redirections, variables, loops, conditionals, functions, subshells |
| **Data Tools** | JSON processing, SQL queries, HTTP requests, Markdown, Liquid templates |
| **Filesystem** | In-memory virtual FS with files, directories, symlinks, permissions |
| **Security** | Complete isolation from host system, optional network with allowlists |

---

## Installation

```elixir
def deps do
  [{:just_bash, "~> 0.1.0"}]
end
```

---

## Quick Examples

### Basic Usage

```elixir
bash = JustBash.new()

# Simple commands
{result, _} = JustBash.exec(bash, "echo 'Hello World'")

# Pipelines
{result, _} = JustBash.exec(bash, "echo 'cherry\napple\nbanana' | sort | head -2")
#=> "apple\nbanana\n"

# Variables and arithmetic  
{result, _} = JustBash.exec(bash, "x=42; echo $((x * 2))")
#=> "84\n"

# Loops
{result, _} = JustBash.exec(bash, "for i in 1 2 3; do echo $i; done")
#=> "1\n2\n3\n"
```

### Initialize with Files

```elixir
bash = JustBash.new(
  files: %{
    "/data/users.csv" => "name,email\nalice,alice@example.com\nbob,bob@example.com",
    "/app/config.json" => ~s({"debug": true, "port": 3000})
  },
  env: %{"APP_ENV" => "production"},
  cwd: "/app"
)

{result, _} = JustBash.exec(bash, "cat /data/users.csv | wc -l")
#=> "3\n"
```

---

## Data Pipeline: The Killer Feature

JustBash shines when processing data. Chain `curl`, `sqlite3`, `jq`, `liquid`, and `markdown` together:

```elixir
bash = JustBash.new(
  network: %{enabled: true, allow_list: ["api.example.com"]},
  files: %{
    "/templates/report.html" => """
    <html>
    <body>
      <h1>{{ title }}</h1>
      {% for user in users %}
        <div>{{ user.name }} - {{ user.email }}</div>
      {% endfor %}
    </body>
    </html>
    """
  }
)

script = ~S"""
# Fetch CSV data and load into SQLite
curl -s https://api.example.com/users.csv | sqlite3 db ".import /dev/stdin users"

# Query with SQL, output as JSON, render with Liquid
sqlite3 db "SELECT * FROM users WHERE active = 1" --json \
  | jq '{title: "Active Users", users: .}' \
  | liquid /templates/report.html
"""

{result, _} = JustBash.exec(bash, script)
```

### More Pipeline Examples

```bash
# ETL: Fetch -> Transform -> Query
curl -s https://api.example.com/orders.json \
  | jq '.[] | select(.total > 100)' \
  | sqlite3 db ".import /dev/stdin big_orders"

# Generate static site from database
sqlite3 blog "SELECT * FROM posts" --json \
  | jq -c '.[]' \
  | while read post; do
      slug=$(echo "$post" | jq -r '.slug')
      echo "$post" | liquid /templates/post.html > "/site/$slug.html"
    done

# Markdown blog post rendering
sqlite3 blog "SELECT content FROM posts WHERE slug='hello'" \
  | markdown \
  | liquid -d /data/layout.json /templates/layout.html

# API response analysis  
curl -s https://api.github.com/repos/elixir-lang/elixir/commits \
  | jq '[.[] | {sha: .sha[:7], author: .commit.author.name}] | .[0:5]'
```

---

## Commands Reference

### File Operations

| Command | Description | Key Flags |
|---------|-------------|-----------|
| `cat` | Concatenate files | `-n` line numbers |
| `ls` | List directory | `-l` `-a` `-R` `-h` |
| `cp` | Copy files | `-r` recursive |
| `mv` | Move/rename | |
| `rm` | Remove files | `-r` `-f` |
| `mkdir` | Create directory | `-p` parents |
| `touch` | Create/update file | |
| `ln` | Create links | `-s` symbolic |
| `find` | Search files | `-name` `-type` `-maxdepth` |
| `stat` | File information | |
| `du` | Disk usage | `-h` `-s` |
| `tree` | Directory tree | |

### Text Processing

| Command | Description | Key Flags |
|---------|-------------|-----------|
| `grep` | Pattern search | `-i` `-v` `-c` `-n` `-o` `-E` `-w` |
| `sed` | Stream editor | `-i` `-E`, `s///` `d` `p` |
| `awk` | Pattern processing | `-F` `-v`, `$1` `NR` `NF` |
| `cut` | Extract columns | `-d` `-f` `-c` |
| `sort` | Sort lines | `-r` `-n` `-u` `-k` |
| `uniq` | Remove duplicates | `-c` `-d` |
| `head` | First N lines | `-n` `-c` |
| `tail` | Last N lines | `-n` `-c` |
| `wc` | Count lines/words | `-l` `-w` `-c` |
| `tr` | Translate chars | `-d` |
| `fold` | Wrap lines | `-w` |
| `nl` | Number lines | |

### Data Tools

| Command | Description | Key Flags |
|---------|-------------|-----------|
| `jq` | JSON processor | `-r` `-c` `-s` — full jq syntax |
| `sqlite3` | SQL database | `--json` `--csv` `.import` `.tables` |
| `curl` | HTTP client | `-X` `-H` `-d` `-o` `-s` `-L` |
| `liquid` | Template engine | `-e` `-d` |
| `markdown` | Markdown → HTML | `--gfm` `--smartypants` |
| `base64` | Encode/decode | `-d` |
| `md5sum` | Hash files | |

### Shell Builtins

| Command | Description |
|---------|-------------|
| `echo` | Print text (`-n` `-e`) |
| `printf` | Formatted output |
| `cd` / `pwd` | Change/print directory |
| `export` / `unset` | Manage variables |
| `test` / `[` | Conditionals |
| `read` | Read input |
| `source` / `.` | Execute script |
| `set` | Shell options (`-e` `-u` `-o pipefail`) |

### Utilities

`basename`, `dirname`, `date`, `seq`, `sleep`, `which`, `env`, `printenv`, `hostname`, `xargs`, `tee`, `comm`, `diff`, `expand`, `paste`, `rev`, `tac`

---

## Shell Syntax Support

### Pipes & Operators

```bash
cmd1 | cmd2 | cmd3          # Pipeline
cmd1 && cmd2                # AND (run cmd2 if cmd1 succeeds)
cmd1 || cmd2                # OR (run cmd2 if cmd1 fails)
! cmd                       # Negate exit status
```

### Redirections

```bash
cmd > file                  # Stdout to file
cmd >> file                 # Append stdout
cmd 2> file                 # Stderr to file  
cmd &> file                 # Both stdout and stderr
cmd < file                  # Stdin from file
cmd <<< "string"            # Here-string
cmd << 'EOF'                # Here-document
content
EOF
```

### Variables

```bash
$VAR                        # Simple expansion
${VAR}                      # Braced expansion
${VAR:-default}             # Default if unset/empty
${VAR:=default}             # Assign default if unset/empty
${VAR:+alternate}           # Alternate if set
${VAR:?error}               # Error if unset/empty
${#VAR}                     # String length
${VAR:2:5}                  # Substring
${VAR#pattern}              # Remove prefix
${VAR%pattern}              # Remove suffix
${VAR/old/new}              # Replace first
${VAR//old/new}             # Replace all
${VAR^^}                    # Uppercase
${VAR,,}                    # Lowercase
```

### Brace Expansion

```bash
{a,b,c}                     # a b c
{1..5}                      # 1 2 3 4 5
{a..z}                      # alphabet
file{1,2,3}.txt             # file1.txt file2.txt file3.txt
```

### Arithmetic

```bash
$((x + y))                  # Arithmetic expansion
$((x ** 2))                 # Exponentiation
$((x > y ? x : y))          # Ternary
$((0xFF))                   # Hex
$((2#1010))                 # Binary
((x++))                     # Increment
```

### Control Flow

```bash
# If statement
if [ condition ]; then
  commands
elif [ condition ]; then
  commands  
else
  commands
fi

# For loop
for item in list; do
  commands
done

# While/Until
while [ condition ]; do
  commands
done

# Case
case $var in
  pattern1) commands ;;
  pattern2|pattern3) commands ;;
  *) default ;;
esac

# Functions
function greet() {
  echo "Hello, $1!"
}
greet "World"
```

### Arrays

```bash
arr=(a b c)                 # Array literal
${arr[0]}                   # Index access
${arr[@]}                   # All elements
${arr[*]}                   # All elements (single word)
${#arr[@]}                  # Array length
```

### Compound Commands

```bash
(cmd1; cmd2)                # Subshell
{ cmd1; cmd2; }             # Group
[[ $x =~ ^[0-9]+$ ]]        # Extended test with regex
```

---

## jq Examples

JustBash includes a comprehensive jq implementation:

```bash
# Basic access
echo '{"name":"alice"}' | jq '.name'                    # "alice"
echo '[1,2,3]' | jq '.[0]'                              # 1
echo '[1,2,3]' | jq '.[]'                               # 1 2 3

# Filtering
echo '[{"a":1},{"a":2}]' | jq '.[] | select(.a > 1)'   # {"a":2}
echo '[1,2,3,4,5]' | jq 'map(. * 2)'                   # [2,4,6,8,10]

# Transformation  
echo '{"a":1,"b":2}' | jq 'keys'                       # ["a","b"]
echo '[3,1,2]' | jq 'sort'                             # [1,2,3]
echo '[[1,2],[3,4]]' | jq 'flatten'                    # [1,2,3,4]

# Construction
echo '{"first":"a","last":"b"}' | jq '{name: .first}'  # {"name":"a"}
echo 'null' | jq '{x: 1, y: 2}'                        # {"x":1,"y":2}

# String operations
echo '"hello"' | jq 'ascii_upcase'                     # "HELLO"
echo '"hello world"' | jq 'split(" ")'                 # ["hello","world"]

# Conditionals
echo '5' | jq 'if . > 3 then "big" else "small" end'  # "big"
```

---

## SQLite Integration

Each named database persists across commands:

```bash
# Create and populate
sqlite3 mydb "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)"
sqlite3 mydb "INSERT INTO users VALUES (1, 'alice', 'alice@example.com')"
sqlite3 mydb "INSERT INTO users VALUES (2, 'bob', 'bob@example.com')"

# Query with different output formats
sqlite3 mydb "SELECT * FROM users"                    # 1|alice|alice@example.com
sqlite3 mydb "SELECT * FROM users" --json             # [{"id":1,"name":"alice",...}]
sqlite3 mydb "SELECT * FROM users" --csv              # id,name,email\n1,alice,...

# Import CSV (auto-creates table from headers)
cat data.csv | sqlite3 mydb ".import /dev/stdin tablename"

# Introspection
sqlite3 mydb ".tables"                                # List tables
sqlite3 mydb ".schema users"                          # Show CREATE statement
```

---

## Network Configuration

Network access is disabled by default:

```elixir
# Enable for all hosts (use with caution)
bash = JustBash.new(network: %{enabled: true})

# Enable with allowlist
bash = JustBash.new(network: %{
  enabled: true,
  allow_list: ["api.github.com", "*.example.com"]
})

# Custom HTTP client for testing
bash = JustBash.new(
  network: %{enabled: true},
  http_client: MyMockHttpClient
)
```

---

## API Reference

```elixir
# Create environment
bash = JustBash.new(
  files: %{path => content},        # Initial files
  env: %{name => value},            # Environment variables
  cwd: "/path",                     # Working directory
  network: %{enabled: bool, allow_list: [patterns]}
)

# Execute commands
{result, bash} = JustBash.exec(bash, "command")
result.stdout      # String
result.stderr      # String  
result.exit_code   # Integer
result.env         # Updated environment map

# Parse without executing
{:ok, ast} = JustBash.parse("echo hello")

# Tokenize
tokens = JustBash.tokenize("echo hello")
```

---

## Limitations

- No real filesystem access (by design)
- No process spawning or job control
- No process substitution `<(cmd)`
- Limited glob patterns
- SQLite databases are in-memory only

---

## Development

```bash
mix deps.get
mix test                    # 1300+ tests
mix dialyzer                # Type checking
mix credo                   # Linting
```

Tested on Elixir 1.15–1.19, OTP 25–28.

---

## License

MIT

---

<p align="center">
  <sub>Built with OpenCode using Claude Opus 4.5</sub>
</p>
