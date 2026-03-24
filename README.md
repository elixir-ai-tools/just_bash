# JustBash

A simulated bash environment with an in-memory virtual filesystem, written in Elixir.

Designed for AI agents that need a secure, sandboxed bash environment.

Supports optional network access via `curl` and `wget` with HTTPS-only enforcement and host allowlists.

> **Note**: This is an Elixir port of [just-bash](https://github.com/vercel-labs/just-bash) by Vercel. The entire codebase was generated through conversational prompting with Claude Opus 4.5 via [OpenCode](https://opencode.ai).

## Security Model

JustBash treats shell code as untrusted by default.

It executes that code in-process against an in-memory virtual filesystem under explicit resource
limits. Those limits are enabled by default and are intended to stop parsing, expansion, jq, output,
filesystem, and traversal abuse from growing without bound. Custom commands passed via `:commands`
are trusted host-side extensions supplied by the library caller, and JustBash does not sandbox them
or provide safety guarantees for them.

- The shell only has access to the provided virtual filesystem
- No access to the real filesystem by default
- No network access by default
- Network access can be enabled with host allowlists — HTTPS-only by default
- Custom commands are outside the sandbox and can bypass the virtual filesystem and network policy

See `SECURITY.md` for the detailed security model, default guarantees, policy presets, and
structured violation handling.

## Installation

```elixir
def deps do
  [{:just_bash, "~> 0.2.0"}]
end
```

## Usage

### Basic API

```elixir
bash = JustBash.new()
{_result, bash} = JustBash.exec(bash, ~s(echo "Hello" > greeting.txt))
{result, _bash} = JustBash.exec(bash, "cat greeting.txt")
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

### Security Policy

Scripts run under resource limits that prevent runaway execution. The defaults
are safe for untrusted code — most users never need to configure this.

```elixir
bash = JustBash.new()                                        # safe defaults
bash = JustBash.new(security: :strict)                       # tighter limits
bash = JustBash.new(security: :relaxed)                      # heavier workloads
bash = JustBash.new(security: [max_steps: 50_000])           # tune one knob
bash = JustBash.new(security: [profile: :strict, max_steps: 50_000])
```

The options you're most likely to tune:

| Option | Default | What it limits |
|--------|---------|----------------|
| `:max_steps` | 100,000 | Total command steps per `exec` call |
| `:max_iterations` | 10,000 | Iterations per loop |
| `:max_output_bytes` | 1,000,000 | Combined stdout + stderr |
| `:max_total_fs_bytes` | 8,000,000 | Total virtual filesystem size |
| `:max_call_depth` | 1,000 | Shell function recursion depth |

All other limits (parsing, expansion, regex, glob, jq) are tuned automatically
by the preset. See `SECURITY.md` for the full model.

### Network Access

Network access is disabled by default. When enabled, only HTTPS is permitted and
an explicit allowlist is required:

```elixir
# Allow specific hosts (HTTPS only)
bash = JustBash.new(
  network: %{
    enabled: true,
    allow_list: ["api.github.com", "*.example.com"]
  }
)

# Allow all hosts
bash = JustBash.new(
  network: %{enabled: true, allow_list: :all}
)

# Also allow plain HTTP (not recommended)
bash = JustBash.new(
  network: %{enabled: true, allow_list: :all, allow_insecure: true}
)

# Custom HTTP client for testing
bash = JustBash.new(
  network: %{enabled: true, allow_list: :all},
  http_client: MyMockHttpClient
)
```

### Custom Commands

Custom commands are trusted extensions supplied by the library caller, not untrusted shell input.
JustBash does not sandbox them and does not provide safety guarantees for them.

Register trusted host-side commands with `commands:`:

```elixir
defmodule MyApp.Commands.Greet do
  @behaviour JustBash.Commands.Command

  @impl true
  def names, do: ["greet", "hello"]

  @impl true
  def execute(bash, args, _stdin) do
    name = Enum.join(args, " ")
    {%{stdout: "Hello, #{name}!\n", stderr: "", exit_code: 0}, bash}
  end
end

bash = JustBash.new(commands: %{"greet" => MyApp.Commands.Greet})
{result, _bash} = JustBash.exec(bash, "hello world")
result.stdout  #=> "Hello, world!\n"
```

Important caveats:

- Custom commands run arbitrary Elixir code in the host BEAM process
- They are not restricted by the virtual filesystem or `network:` policy
- Registration keys must appear in `names/0`; aliases from `names/0` are registered automatically
- Shell functions still win over custom commands at execution time
- Protected stateful builtins such as `cd`, `export`, `trap`, and `return` cannot be overridden

### Execute Script Files

```elixir
# Run a script from the virtual filesystem
bash = JustBash.new(files: %{"/script.sh" => "echo hello"})
{result, bash} = JustBash.exec_file(bash, "/script.sh")
```

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

`cat`, `chmod`, `chown`, `cp`, `du`, `file`, `find`, `ln`, `ls`, `mkdir`, `mktemp`, `mv`, `readlink`, `realpath`, `rm`, `stat`, `touch`, `tree`

### Text Processing

`awk`, `base64`, `comm`, `cut`, `diff`, `expand`, `fold`, `grep`, `head`, `md5sum`, `nl`, `paste`, `rev`, `sed`, `sha256sum`, `shasum`, `sort`, `tac`, `tail`, `tr`, `uniq`, `wc`, `xargs`

### Data Processing

`jq` (JSON), `markdown` (Markdown → HTML)

### Network

`curl`, `wget`

### Shell Builtins

`echo`, `printf`, `cd`, `pwd`, `eval`, `export`, `unset`, `set`, `test`, `[`, `[[`, `true`, `false`, `:`, `command`, `source`, `.`, `read`, `exit`, `return`, `local`, `declare`, `typeset`, `break`, `continue`, `shift`, `getopts`, `trap`, `type`

### Utilities

`arch`, `basename`, `date`, `dirname`, `env`, `hostname`, `id`, `nproc`, `printenv`, `seq`, `sleep`, `tee`, `uname`, `which`, `whoami`, `yes`

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
- **Indexed arrays**: `arr=(...)`, `${arr[0]}`, `${arr[@]}`, `${#arr[@]}`
- **Associative arrays**: `declare -A map`, `map[key]=value`, `${map[key]}`
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
result.violation   # Structured security failure metadata or nil

# Execute script from virtual filesystem
{result, bash} = JustBash.exec_file(bash, "/path/to/script.sh")

# Parse without executing
{:ok, ast} = JustBash.parse("echo hello")

# Format script
{:ok, formatted} = JustBash.format("if true;then echo yes;fi")
```

## Upgrading

### From 0.1.x / 0.2.x

Top-level `max_iterations` and `max_call_depth` options have been removed in favor of the
centralized `security:` option. Passing the old options will raise an `ArgumentError` with
migration guidance.

```elixir
# Before
bash = JustBash.new(max_iterations: 5_000, max_call_depth: 100)

# After
bash = JustBash.new(security: [max_iterations: 5_000, max_call_depth: 100])
```

All 25 resource limits are now configured through `security:`. See `SECURITY.md` for the
full list and preset details.

## Development

```bash
mix deps.get
mix test           # Unit, integration, property-based, and bash-comparison tests
mix dialyzer       # Type checking
mix credo --strict # Linting
```

## License

MIT
