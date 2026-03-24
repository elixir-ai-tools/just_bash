# JustBash Security Guide

JustBash is an in-process shell interpreter for untrusted code.

What it does:

- parses and executes shell code against an in-memory virtual filesystem
- applies resource limits by default so parsing, expansion, execution, jq processing, output,
  filesystem growth, and recursive traversal fail before they can grow without bound
- returns structured violation metadata when a security limit trips

What it does not do:

- create an OS process sandbox
- isolate unsafe custom Elixir commands
- make arbitrary host-side Elixir code safe

The intended model is: untrusted shell input is normal, limits are always on, and callers tune the
policy only when they need stricter or more relaxed budgets.

## Core Model

- `JustBash.exec/2` parses the input, evaluates it in the current JustBash environment, and returns
  `{result, bash}`
- the `bash` state contains the virtual filesystem, environment, functions, traps, and security
  policy
- the `result` contains stdout, stderr, exit code, env, and optional `violation` metadata
- Shell code runs against an in-memory virtual filesystem
- Real filesystem access is not available by default
- Network access is disabled by default
- When network access is enabled, host allowlists and HTTPS-only rules still apply unless relaxed
- Custom commands registered through `:commands` are trusted host-side extensions and are outside
  JustBash's sandboxing guarantees

In practical terms, this means untrusted shell code can mutate the JustBash virtual state, but it
should not be able to grow that state without hitting explicit quotas first.

## Security Configuration

Use the `:security` option to configure limits. Most users never need to change this.

```elixir
bash = JustBash.new()                                        # safe defaults
bash = JustBash.new(security: :strict)                       # tighter limits
bash = JustBash.new(security: :relaxed)                      # heavier workloads
bash = JustBash.new(security: [max_steps: 50_000])           # tune one knob
bash = JustBash.new(security: [profile: :strict, max_steps: 50_000])
```

### Presets

- `:default` — safe defaults for untrusted code
- `:strict` — tighter budgets (~20% of default) for adversarial workloads
- `:relaxed` — looser budgets (~10× default) for trusted or internal workloads

### User-facing options

| Option | Default | What it limits |
|--------|---------|----------------|
| `:max_steps` | 100,000 | Total command steps per `exec` call |
| `:max_iterations` | 10,000 | Iterations per loop |
| `:max_output_bytes` | 1,000,000 | Combined stdout + stderr |
| `:max_total_fs_bytes` | 8,000,000 | Total virtual filesystem size |
| `:max_call_depth` | 1,000 | Shell function recursion depth |

All other limits (parsing, expansion, regex, glob, jq, etc.) are tuned automatically
by the preset. Internal limits can still be overridden if needed — see
`JustBash.Security.Policy.all_keys/0`.

## What Is Limited

JustBash enforces budgets across parsing, expansion, execution, filesystem growth, output growth,
regex work, jq work, and recursive traversal.

Examples include:

- parser input bytes, token count, AST size, and nesting depth
- loop iterations, execution depth, function call depth, and total execution steps
- stdout/stderr bytes
- virtual filesystem per-file and total byte quotas
- environment and array growth
- brace expansion, glob matches, and recursive file walks
- HTTP response body size
- regex pattern and input size
- jq result count, jq recursion depth, jq input size/depth, and jq work items

These limits are part of the active security policy and are enforced during execution, not as a
best-effort warning after the fact.

## Structured Failures

Security failures are available both as stderr text and structured metadata.

```elixir
{result, bash} = JustBash.exec(JustBash.new(security: [max_steps: 1]), "echo one; echo two")

result.exit_code
#=> 1

result.stderr
#=> "bash: execution step limit exceeded\n"

result.violation.kind
#=> :execution_step_limit_exceeded
```

The interpreter also keeps the current violation in its runtime budget state, but callers should
prefer inspecting `result.violation`.

Common violation kinds include:

- `:output_limit_exceeded`
- `:execution_step_limit_exceeded`
- `:environment_size_limit_exceeded`
- `:array_entry_limit_exceeded`
- `:array_size_limit_exceeded`
- `:glob_match_limit_exceeded`
- `:file_walk_limit_exceeded`
- `:regex_pattern_limit_exceeded`
- `:regex_input_limit_exceeded`
- `:http_body_limit_exceeded`
- `:jq_result_limit_exceeded`
- `:jq_recursion_depth_limit_exceeded`

## Guarantees

JustBash is intended to prevent untrusted shell code from blowing up the host BEAM process through
unbounded parsing, expansion, output growth, filesystem growth, jq fanout, or similar resource
abuse.

The library aims to fail closed:

- when a limit is exceeded, execution stops
- the result includes a non-zero exit code
- later commands in the same run do not continue
- stateful operations that exceed quotas do not partially persist beyond the allowed budget

More concretely, the library aims to guarantee:

- shell code only sees the virtual filesystem and configured network policy
- default execution is resource-limited even if the caller does not pass custom limits
- quota failures are observable as structured metadata, not only as human-readable stderr text
- callers can tighten or relax budgets through one canonical `:security` configuration path

## Non-Goals

JustBash does **not** claim:

- OS-level isolation
- protection against unsafe custom commands
- protection against arbitrary Elixir code executed by the embedding host
- equivalent guarantees to a separate process or container sandbox

It is an in-process untrusted-code engine with aggressive resource controls, not a kernel sandbox.

If you need protection from arbitrary native code, arbitrary BEAM code, or host-wide resource
contention beyond interpreter quotas, use a separate process or container boundary in addition to
JustBash.

## Recommended Host Usage

- treat `JustBash.new()` as the baseline for untrusted code
- enable network access only when needed
- keep custom commands out of untrusted environments unless they are intentionally trusted
- choose `:strict` for especially adversarial workloads
- inspect `result.violation` for programmatic handling and telemetry

## Tuning Guidance

Tighten limits when:

- users can submit arbitrary scripts directly
- workloads are short-lived and should fail fast
- network responses and jq transforms should stay small

Relax limits when:

- the caller controls the scripts
- larger JSON documents or outputs are expected
- the environment is internal and usage patterns are well understood

## Reporting Security Issues

If you find a way to crash the interpreter, bypass a limit, or trigger unexpected host-side impact,
open a security issue or report it privately through the project's preferred disclosure channel.
