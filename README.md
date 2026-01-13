# JustBash

[![CI](https://github.com/ivarvong/just_bash/actions/workflows/ci.yml/badge.svg)](https://github.com/ivarvong/just_bash/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/just_bash.svg)](LICENSE)

A sandboxed bash interpreter with virtual filesystem, written in pure Elixir. Execute bash scripts safely in memory with no access to the real filesystem or network.

> **Alpha Quality** - This project is 100% LLM-generated code (Claude) and should be considered experimental. Use at your own risk.

## Features

- **Sandboxed execution** - All commands run in memory, isolated from the real system
- **Virtual filesystem** - Complete in-memory filesystem with files, directories, and symlinks
- **50+ commands** - Core utilities, text processing, data tools
- **Full bash syntax** - Pipes, redirections, variables, loops, conditionals, functions
- **Data pipelines** - curl, sqlite3, jq integration for fetching and transforming data
- **Network control** - Optional HTTP access with allowlist filtering

## Quick Start

```elixir
bash = JustBash.new()

# Simple command
{result, _} = JustBash.exec(bash, "echo 'Hello, World!'")
result.stdout  # "Hello, World!\n"

# Pipelines
{result, _} = JustBash.exec(bash, "echo 'banana\napple\ncherry' | sort | head -2")
result.stdout  # "apple\nbanana\n"

# Variables and arithmetic
{result, _} = JustBash.exec(bash, "x=5; echo $((x * x))")
result.stdout  # "25\n"
```

## Data Pipelines

Fetch data, load into SQLite, query, and transform with jq:

```elixir
bash = JustBash.new(
  network: %{enabled: true, allow_list: ["api.example.com"]}
)

script = ~S"""
# Fetch CSV and load into SQLite
curl -s https://api.example.com/users.csv | sqlite3 db ".import /dev/stdin users"

# Query and transform with jq
sqlite3 db "SELECT * FROM users WHERE active = 1" --json | jq -r '.[].email'
"""

{result, _} = JustBash.exec(bash, script)
```

## Supported Commands

### File Operations
`cat`, `ls`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `ln`, `readlink`, `stat`, `du`, `find`, `tree`, `file`

### Text Processing
`grep`, `sed`, `awk`, `sort`, `uniq`, `head`, `tail`, `wc`, `cut`, `tr`, `paste`, `fold`, `nl`, `tac`, `rev`, `expand`, `comm`, `diff`

### Data Tools
`curl` - HTTP client with network sandboxing
`jq` - JSON processor
`sqlite3` - In-memory SQL database with `.import` for CSV

### Utilities
`echo`, `printf`, `pwd`, `cd`, `env`, `export`, `unset`, `test`, `[`, `seq`, `date`, `sleep`, `basename`, `dirname`, `which`, `xargs`, `tee`, `base64`, `md5sum`

## Shell Features

- **Pipes** - `cmd1 | cmd2 | cmd3`
- **Redirections** - `>`, `>>`, `2>&1`, `/dev/null`
- **Variables** - `$VAR`, `${VAR:-default}`, `${VAR:=set}`, `${VAR:+alt}`, `${#VAR}`
- **Command substitution** - `$(cmd)` and backticks
- **Arithmetic** - `$((x + y))`, `$((x ** 2))`, comparisons, ternary
- **Control flow** - `if/elif/else/fi`, `for/do/done`, `while/until`, `case/esac`
- **Logical operators** - `&&`, `||` with short-circuit evaluation
- **Functions** - `function name() { ... }` or `name() { ... }`
- **Brace expansion** - `{a,b,c}`, `{1..5}`

## SQLite Integration

Named databases persist across commands:

```elixir
bash = JustBash.new()

# Create and populate
{_, bash} = JustBash.exec(bash, ~S"""
sqlite3 mydb "CREATE TABLE users (id INTEGER, name TEXT, email TEXT)"
sqlite3 mydb "INSERT INTO users VALUES (1, 'alice', 'alice@example.com')"
sqlite3 mydb "INSERT INTO users VALUES (2, 'bob', 'bob@example.com')"
""")

# Query with different output formats
{result, _} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM users' --json")
# [{"id":1,"name":"alice","email":"alice@example.com"},{"id":2,"name":"bob","email":"bob@example.com"}]

{result, _} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM users' --csv")
# id,name,email
# 1,alice,alice@example.com
# 2,bob,bob@example.com

# Import CSV (auto-creates table from headers)
{_, bash} = JustBash.exec(bash, ~S"""
echo "name,score
alice,100
bob,85" | sqlite3 mydb ".import /dev/stdin scores"
""")
```

## Network Access

Network is disabled by default. Enable with allowlist:

```elixir
# Allow specific hosts
bash = JustBash.new(network: %{
  enabled: true,
  allow_list: ["api.github.com", "*.example.com"]
})

# Or allow all (use with caution)
bash = JustBash.new(network: %{enabled: true})
```

## Configuration

```elixir
JustBash.new(
  files: %{"/data/config.json" => ~s({"key": "value"})},  # Initial files
  env: %{"API_KEY" => "secret"},                          # Environment variables  
  cwd: "/app",                                            # Working directory
  network: %{enabled: true, allow_list: ["*.api.com"]},   # Network access
  http_client: MyMockClient                               # Custom HTTP client for testing
)
```

## Installation

```elixir
def deps do
  [{:just_bash, "~> 0.1.0"}]
end
```

## Testing

```bash
mix test              # Run tests
mix dialyzer          # Type checking
mix credo --strict    # Linting
```

## Known Limitations

- No real filesystem access (by design)
- No process spawning or job control
- No arrays or associative arrays (variables are strings)
- No process substitution `<(cmd)`
- Limited glob expansion
- SQLite databases are in-memory only

## License

MIT

## Acknowledgments

This project was 100% generated by Claude (Anthropic) as an experiment in LLM-assisted development. The entire codebase—including the parser, interpreter, 50+ commands, and test suite—was written through conversational prompting without human-written code.
