# JustBash

[![Hex.pm](https://img.shields.io/hexpm/v/just_bash.svg)](https://hex.pm/packages/just_bash)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/just_bash)
[![CI](https://github.com/ivarvong/just_bash/actions/workflows/ci.yml/badge.svg)](https://github.com/ivarvong/just_bash/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/just_bash.svg)](LICENSE)

A simulated bash environment with a virtual filesystem, written in Elixir. Designed for AI agents and other use cases that need safe, sandboxed bash execution.

## Why JustBash?

- **Safe execution** - All commands run in memory with no access to the real filesystem
- **Deterministic** - Same input always produces the same output (except `date`)
- **Portable** - Pure Elixir, no external dependencies or shell required
- **AI-friendly** - Perfect for LLM agents that need to execute bash commands safely

## Features

- **In-memory virtual filesystem** - All file operations happen in memory
- **Full bash parsing** - Lexer and recursive descent parser for bash syntax
- **Pipes** - `cmd1 | cmd2 | cmd3` with stdout flowing to stdin
- **Redirections** - `>`, `>>`, redirect to `/dev/null`
- **Variable expansion** - `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR:=default}`, `${VAR:+alt}`, `${#VAR}`
- **Command substitution** - `$(cmd)` and backticks
- **Arithmetic expansion** - `$((expr))` with full operator support (+, -, *, /, %, **, comparisons, bitwise, ternary)
- **Control flow** - `if/elif/else/fi`, `for x in ...; do; done`, `while/until`
- **Logical operators** - `&&`, `||`, `!` with short-circuit evaluation
- **Test command** - `[ ]` and `test` with string, numeric, and file tests

## Installation

Add `just_bash` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:just_bash, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a new bash environment
bash = JustBash.new()

# Execute a command
{result, bash} = JustBash.exec(bash, "echo 'Hello, World!'")
IO.puts(result.stdout)  # "Hello, World!\n"

# Create with initial files
bash = JustBash.new(files: %{
  "/data/users.txt" => "alice\nbob\ncharlie"
})

# Pipelines work!
{result, _} = JustBash.exec(bash, "cat /data/users.txt | sort | uniq -c")
IO.puts(result.stdout)
# 1 alice
# 1 bob
# 1 charlie

# Environment variables
bash = JustBash.new(env: %{"MY_VAR" => "hello"})
{result, _} = JustBash.exec(bash, "echo $MY_VAR")
# "hello\n"
```

## Supported Commands

### File Operations
| Command | Description | Flags |
|---------|-------------|-------|
| `cat` | Concatenate and display files | stdin support |
| `ls` | List directory contents | `-l`, `-a` |
| `cp` | Copy files | |
| `mv` | Move/rename files | |
| `rm` | Remove files | `-r`, `-f` |
| `mkdir` | Create directories | `-p` |
| `touch` | Create empty files | |

### Text Processing
| Command | Description | Flags |
|---------|-------------|-------|
| `grep` | Search for patterns | `-i`, `-v`, stdin |
| `sort` | Sort lines | `-r`, `-n`, `-u`, stdin |
| `uniq` | Filter duplicate lines | `-c`, stdin |
| `head` | Output first lines | `-n`, stdin |
| `tail` | Output last lines | `-n`, stdin |
| `wc` | Count lines/words/chars | `-l`, `-w`, `-c`, stdin |
| `tr` | Translate characters | ranges like `a-z` |

### Utilities
| Command | Description |
|---------|-------------|
| `echo` | Display text (`-n`, `-e` flags) |
| `printf` | Formatted output |
| `pwd` | Print working directory |
| `cd` | Change directory |
| `export` | Set environment variables |
| `unset` | Remove environment variables |
| `test` / `[` | Evaluate conditional expressions |
| `true` / `false` / `:` | Return exit codes |
| `seq` | Generate number sequences |
| `date` | Display current date/time |
| `basename` / `dirname` | Extract path components |
| `read` | Read input into variable |
| `exit` | Exit with code |

## Examples

### FizzBuzz

```elixir
bash = JustBash.new()
{result, _} = JustBash.exec(bash, ~S"""
for i in $(seq 1 15); do
  if [ $((i % 15)) -eq 0 ]; then
    echo "FizzBuzz"
  elif [ $((i % 3)) -eq 0 ]; then
    echo "Fizz"
  elif [ $((i % 5)) -eq 0 ]; then
    echo "Buzz"
  else
    echo $i
  fi
done
""")
IO.puts(result.stdout)
```

### Data Processing Pipeline

```elixir
bash = JustBash.new(files: %{
  "/data/users.txt" => "alice\nbob\nalice\ncharlie\nbob\nalice"
})

{result, _} = JustBash.exec(bash, "cat /data/users.txt | sort | uniq -c | sort -rn")
IO.puts(result.stdout)
# 3 alice
# 2 bob
# 1 charlie
```

### Arithmetic

```elixir
bash = JustBash.new()
{result, _} = JustBash.exec(bash, ~S"""
x=42
echo "x squared = $((x ** 2))"
echo "Is even? $((x % 2 == 0 ? 1 : 0))"
""")
IO.puts(result.stdout)
# x squared = 1764
# Is even? 1
```

### File Manipulation

```elixir
bash = JustBash.new()
{_, bash} = JustBash.exec(bash, "mkdir -p /app/src")
{_, bash} = JustBash.exec(bash, "echo 'console.log(\"hello\")' > /app/src/index.js")
{result, _} = JustBash.exec(bash, "cat /app/src/index.js")
IO.puts(result.stdout)
# console.log("hello")
```

## API Reference

### `JustBash.new(opts \\ [])`

Creates a new bash environment.

**Options:**
- `:files` - Map of path => content for initial files
- `:env` - Map of environment variables
- `:cwd` - Starting working directory (default: `"/home/user"`)

**Returns:** A `%JustBash{}` struct

### `JustBash.exec(bash, command)`

Executes a bash command string.

**Parameters:**
- `bash` - A `%JustBash{}` struct
- `command` - A string containing the bash command(s) to execute

**Returns:** `{result, updated_bash}` where result is a map containing:
- `:stdout` - Standard output as a string
- `:stderr` - Standard error as a string
- `:exit_code` - Exit code (0 = success)
- `:env` - Final environment variables

## Use Cases

- **AI Agents** - Safe bash execution for LLM-powered coding assistants
- **Testing** - Test bash scripts without touching the real filesystem
- **Education** - Learn bash in a safe sandbox
- **CI/CD Simulation** - Prototype build scripts
- **Demos** - Show bash examples in documentation without side effects

## Architecture

JustBash consists of several components:

- **Lexer** (`JustBash.Parser.Lexer`) - Tokenizes bash source code
- **Parser** (`JustBash.Parser`) - Recursive descent parser producing an AST
- **AST** (`JustBash.AST`) - Abstract syntax tree node definitions
- **Interpreter** (`JustBash`) - Executes AST nodes
- **Virtual Filesystem** (`JustBash.Fs.InMemoryFs`) - In-memory filesystem implementation
- **Arithmetic** (`JustBash.Arithmetic`) - Arithmetic expression parser and evaluator

## Known Limitations

- No real filesystem access (by design)
- No network access
- No process spawning or job control
- No arrays or associative arrays
- No process substitution (`<(cmd)`)
- No here documents (`<<EOF`)
- No glob expansion (`*`, `?`, `[...]`)
- Functions are parsed but not executed

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Running Tests

```bash
mix test
```

### Running the Demo

```bash
mix run demo.exs
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

This project was inspired by the need for safe bash execution in AI agent environments.
