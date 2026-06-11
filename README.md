# JustBash

A simulated bash environment with an in-memory virtual filesystem, written in Elixir.

Designed for AI agents that need a secure, sandboxed bash environment.

Supports optional network access via `curl` and `wget` with HTTPS-only enforcement and host allowlists.

> **Note**: This is an Elixir port of [just-bash](https://github.com/vercel-labs/just-bash) by Vercel. The entire codebase was generated through conversational prompting with Claude Opus 4.5 via [OpenCode](https://opencode.ai).

## Security Model

JustBash treats shell code as untrusted and sandboxes it in memory. Custom commands passed via
`:commands` are trusted host-side extensions supplied by the library caller, and JustBash does not
sandbox them or provide safety guarantees for them.

- The shell only has access to the provided virtual filesystem
- No access to the real filesystem by default
- No network access by default
- Network access can be enabled with host allowlists — HTTPS-only by default
- Custom commands are outside the sandbox and can bypass the virtual filesystem and network policy

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

#### Custom command context

Pass caller data into custom commands with the `:context` option. It is stored on the `JustBash`
struct as `context` (default `%{}`) and is readable inside any custom command as `bash.context`.
Builtins and the interpreter ignore it.

```elixir
defmodule MyApp.Commands.Whoami do
  @behaviour JustBash.Commands.Command

  @impl true
  def names, do: ["whoami_ctx"]

  @impl true
  def execute(bash, _args, _stdin) do
    user = Map.get(bash.context, :user, "anonymous")
    {%{stdout: "#{user}\n", stderr: "", exit_code: 0}, bash}
  end
end

bash =
  JustBash.new(
    context: %{user: "alice"},
    commands: %{"whoami_ctx" => MyApp.Commands.Whoami}
  )

{result, _bash} = JustBash.exec(bash, "whoami_ctx")
result.stdout  #=> "alice\n"
```

#### Updating context after construction

The `:context` option seeds caller data at construction. To add or update entries *afterward*, use
the `put_context/3` and `get_context/3` accessors (modeled on `Plug.Conn.put_private/3`). Both target
the same `context` map, keys are atoms, and the map is ignored by builtins and the interpreter.

```elixir
defmodule MyApp.Commands.Counter do
  @behaviour JustBash.Commands.Command

  @impl true
  def names, do: ["counter_ctx"]

  @impl true
  def execute(bash, _args, _stdin) do
    count = JustBash.get_context(bash, :count, 0)
    {%{stdout: "#{count}\n", stderr: "", exit_code: 0}, bash}
  end
end

bash =
  JustBash.new(commands: %{"counter_ctx" => MyApp.Commands.Counter})
  |> JustBash.put_context(:count, 41)

{result, _bash} = JustBash.exec(bash, "counter_ctx")
result.stdout  #=> "41\n"
```

Important caveats:

- Custom commands run arbitrary Elixir code in the host BEAM process
- They are not restricted by the virtual filesystem or `network:` policy
- Registration keys must appear in `names/0`; aliases from `names/0` are registered automatically
- Shell functions still win over custom commands at execution time
- Protected stateful builtins such as `cd`, `export`, `trap`, and `return` cannot be overridden

### Namespaced CLIs (`JustBash.CLI`)

When a single tool needs many subcommands — `acme pr review`, `acme product list` — don't
hand-roll a `case` router, manual `--help`, and ad-hoc error strings in `execute/3`.
`JustBash.CLI` is a declarative subcommand layer that gives you **routing**, **typed
argument parsing**, and **auto-generated help, errors, and docs** from a single source of
truth. A CLI is plain data (a `%JustBash.CLI{}` tree) that registers like any other
command:

```elixir
alias JustBash.CLI
alias JustBash.Commands.Command

cli =
  CLI.new("acme", doc: "Acme operations toolkit", commands: [
    CLI.command("pr", doc: "Pull request management", commands: [
      CLI.command("review",
        doc: "Review a pull request",
        flags: [
          report:  [type: :integer, required: true, doc: "ID of the report to review"],
          format:  [type: :string, default: "text", values: ~w(text json), doc: "Output format"],
          verbose: [type: :boolean, short: "-v"]
        ],
        run: fn inv ->
          tag = if inv.flags.verbose, do: "[v] ", else: ""
          {Command.ok("#{tag}report #{inv.flags.report} as #{inv.flags.format}\n"), inv.bash}
        end)
    ])
  ])

bash = JustBash.new(commands: %{"acme" => cli})
{result, _} = JustBash.exec(bash, "acme pr review --report 42 --format json")
result.stdout  #=> "report 42 as json\n"
```

Each leaf's `:run` handler takes a single `%JustBash.CLI.Invocation{}` (`flags`, `args`,
`bash`, `stdin`, `path`) and returns `{result, bash}` — the same contract as a plain
custom command, so handlers keep full access to `bash.fs`, `bash.context`, etc. Use a
capture (`run: &Acme.PR.review/1`) to keep handler logic in named, testable functions.

Help, `did you mean` suggestions, and usage-bearing errors come for free and are
consistent across every CLI — which is exactly what an agent needs to recover from a typo
in one turn:

```text
$ acme pr review --help
acme pr review - Review a pull request

Usage: acme pr review --report <int> [--format text|json] [-v]

Options:
  --report <int>       ID of the report to review (required)
  --format text|json   Output format (values: text, json) (default: text)
  -v, --verbose

$ acme pr reviw
acme: unknown command 'pr reviw'
Did you mean 'pr review'?
Run 'acme --help' for available commands.      # exit code 2

$ acme pr review
acme pr review: missing required flag: --report
Usage: acme pr review --report <int> [--format text|json] [-v]   # exit code 2
```

Because the spec is declarative, you can introspect it to generate the tool documentation
that goes into an agent's system prompt — from the same source as the runtime behavior:

```elixir
JustBash.CLI.describe(cli)
#=> %{name: "acme", doc: "...", commands: [%{path: ["pr", "review"], flags: [...], ...}]}

JustBash.CLI.render_docs(cli, format: :markdown)  # a markdown manual
```

A few options on `command/2` cover the rough edges a real consumer hits:

- **`:examples`** — worked examples, co-located with the command and surfaced in `--help`,
  `describe/1`, and `render_docs`: `examples: ["acme pr review --report 42", %{cmd: "...", doc: "..."}]`.
- **`:validate`** — a `(Invocation -> :ok | {:error, msg})` callback for cross-field rules
  (e.g. `start <= end`); an error produces the same exit-2 + usage line as a flag error, so
  every failure has one contract. (A flag `:transform` may likewise return `{:error, msg}`
  for single-field checks like a numeric range.)
- **`allow_unknown_flags: true`** — collect undeclared flags into `inv.extra_flags` (a raw
  token list) instead of erroring, for a leaf that forwards them to a dynamic backend.
- **`visible?: fn bash -> ... end`** — make a node *absent* (unroutable and omitted from
  help/`describe`) for callers it rejects, decided from `bash.context`. Pass the same `bash`
  to `describe(cli, bash)` to get the catalog that caller sees. For fully dynamic trees,
  build the `%JustBash.CLI{}` per session and conditionally append gated groups — the tree
  is plain data, so routing, help, and `describe` always reflect exactly what you built.
- **`on_missing_subcommand: :help`** — print the command listing at exit 0 (instead of a
  usage error) when a group is invoked with no subcommand.

For handler-level unit tests, drive through `CLI.run/4` or `CLI.invoke(spec, path, args, bash, stdin)`
rather than hand-building an `%Invocation{}` — only the parser merges flag defaults, so a
hand-built invocation would see `nil` where a `:default` should be.

If you prefer a CLI to live as a module alongside your other command modules, `use
JustBash.CLI` and define `spec/0` (conventional `use`-wiring, not a DSL):

```elixir
defmodule Acme.CLI do
  use JustBash.CLI

  @impl true
  def spec, do: JustBash.CLI.new("acme", doc: "Acme toolkit", commands: [...])
end

bash = JustBash.new(commands: %{"acme" => Acme.CLI})
```

For a complete before/after, compare [`eval/commands/kv.ex`](eval/commands/kv.ex) (a
hand-rolled router with help text duplicated by hand) against
[`eval/commands/kv_cli.ex`](eval/commands/kv_cli.ex) (the same tool on `JustBash.CLI`,
where only the storage logic remains). CLI handlers carry the same trust model and crash
isolation as any custom command — they are host code and are **not** sandboxed.

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

# Execute script from virtual filesystem
{result, bash} = JustBash.exec_file(bash, "/path/to/script.sh")

# Parse without executing
{:ok, ast} = JustBash.parse("echo hello")

# Format script
{:ok, formatted} = JustBash.format("if true;then echo yes;fi")
```

## Development

```bash
mix deps.get
mix test           # Unit, integration, property-based, and bash-comparison tests
mix dialyzer       # Type checking
mix credo --strict # Linting
```

## License

MIT
