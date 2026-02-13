# JustBash

A simulated bash environment with an in-memory virtual filesystem, written in Elixir.

Designed for AI agents that need a secure, sandboxed bash environment.

Supports optional network access via `curl` with secure-by-default URL filtering.

> **Note**: This is an Elixir port of [just-bash](https://github.com/vercel-labs/just-bash) by Vercel. The entire codebase was generated through conversational prompting with Claude Opus 4.5 via [OpenCode](https://opencode.ai).

## Security Model

- The shell only has access to the provided virtual filesystem
- No access to the real filesystem by default
- No network access by default
- Network access can be enabled with URL allowlists

## Installation

```elixir
def deps do
  [{:just_bash, "~> 0.1.0"}]
end
```

## Usage

### Basic API

```elixir
bash = JustBash.new()
{result, _} = JustBash.exec(bash, ~s(echo "Hello" > greeting.txt))
{result, _} = JustBash.exec(bash, "cat greeting.txt")
result.stdout  #=> "Hello\n"
result.exit_code  #=> 0
```

### Configuration

```elixir
bash = JustBash.new(
  files: %{"/data/file.txt" => "content"},  # Initial files
  env: %{"MY_VAR" => "value"},              # Environment variables
  cwd: "/app"                                # Starting directory
)
```

### Network Access

Network access is disabled by default. Enable it with allowlists:

```elixir
# Allow specific hosts
bash = JustBash.new(
  network: %{
    enabled: true,
    allow_list: ["api.github.com", "*.example.com"]
  }
)

# Custom HTTP client for testing
bash = JustBash.new(
  network: %{enabled: true},
  http_client: MyMockHttpClient
)
```

### Execute Script Files

```elixir
# Run a script from the real filesystem in the sandbox
{result, bash} = JustBash.exec_file("script.sh")

# With options
JustBash.exec_file("script.sh",
  files: %{"/data/input.txt" => "hello"},
  network: %{enabled: true}
)
```

### Content Adapters (Dynamic Files)

Files can be backed by functions or external resources instead of static strings:

```elixir
alias JustBash.Fs.Content.FunctionContent

bash = JustBash.new(
  files: %{
    # Static file (default)
    "/static.txt" => "fixed content",

    # Function-backed file (called on each read)
    "/dynamic.txt" => fn -> "Generated at #{DateTime.utc_now()}" end,

    # MFA tuple (serialization-friendly)
    "/upper.txt" => FunctionContent.new({String, :upcase, ["hello"]}),

    # S3-backed file (requires custom client)
    "/remote.txt" => S3Content.new(
      bucket: "my-bucket",
      key: "file.txt",
      client: MyS3Client
    )
  }
)

# Function is called on each read
{result, bash} = JustBash.exec(bash, "cat /dynamic.txt")

# Materialize to cache function results
{:ok, bash} = JustBash.materialize_files(bash)
# Now functions won't be called again
```

See `examples/content_adapters.exs` for more examples.

### Sigil

```elixir
import JustBash.Sigil

result = ~b"echo hello"
result.stdout  #=> "hello\n"

# Modifiers
~b"echo hello"t  # trimmed output
~b"echo hello"s  # stdout only
~b"exit 42"e     # exit code
```

## Supported Commands

### File Operations

`cat`, `cp`, `file`, `find`, `ln`, `ls`, `mkdir`, `mv`, `readlink`, `rm`, `stat`, `touch`, `tree`, `du`

### Text Processing

`awk`, `base64`, `comm`, `cut`, `diff`, `expand`, `fold`, `grep`, `head`, `md5sum`, `nl`, `paste`, `rev`, `sed`, `sort`, `tac`, `tail`, `tr`, `uniq`, `wc`, `xargs`

### Data Processing

`jq` (JSON), `markdown` (Markdown → HTML)

### Network

`curl`

### Shell Builtins

`echo`, `printf`, `cd`, `pwd`, `export`, `unset`, `set`, `test`, `[`, `[[`, `true`, `false`, `:`, `source`, `.`, `read`, `exit`, `return`, `local`, `declare`, `break`, `continue`, `shift`, `getopts`, `trap`

### Utilities

`basename`, `dirname`, `date`, `env`, `hostname`, `printenv`, `seq`, `sleep`, `tee`, `which`

## Shell Features

- **Pipes**: `cmd1 | cmd2`
- **Redirections**: `>`, `>>`, `2>`, `&>`, `<`, `<<<`, heredocs
- **Command chaining**: `&&`, `||`, `;`
- **Variables**: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR:=value}`, `${#VAR}`, `${VAR:start:len}`, `${VAR#pattern}`, `${VAR%pattern}`, `${VAR/old/new}`, `${VAR^^}`, `${VAR,,}`
- **Brace expansion**: `{a,b,c}`, `{1..10}`, `{a..z}`
- **Arithmetic**: `$((expr))` with full operators
- **Glob patterns**: `*`, `?`, `[...]`
- **Control flow**: `if/elif/else/fi`, `for/while/until`, `case/esac`
- **Functions**: `function name { ... }` or `name() { ... }`
- **Arrays**: `arr=(...)`, `${arr[0]}`, `${arr[@]}`, `${#arr[@]}`
- **Subshells**: `(cmd)` and command groups `{ cmd; }`

## Default Layout

When created without options, JustBash provides a Unix-like directory structure:

- `/home/user` - Default working directory (and `$HOME`)
- `/bin`, `/usr/bin` - Binary directories
- `/tmp` - Temporary files

## API Reference

```elixir
# Create environment
bash = JustBash.new(opts)

# Execute command
{result, bash} = JustBash.exec(bash, "command")
result.stdout      # String
result.stderr      # String
result.exit_code   # Integer
result.env         # Updated environment

# Parse without executing
{:ok, ast} = JustBash.parse("echo hello")

# Format script
{:ok, formatted} = JustBash.format("if true;then echo yes;fi")
```

## Development

```bash
mix deps.get
mix test           # 2400+ tests
mix dialyzer       # Type checking
mix credo          # Linting
```

## License

MIT
