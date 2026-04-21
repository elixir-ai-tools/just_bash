# Upgrading

## 0.3.x → 0.4.0

The filesystem modules have been renamed to use uppercase acronyms:

- `JustBash.Fs` → `JustBash.FS`
- `JustBash.Fs.InMemoryFs` → `JustBash.FS.InMemoryFS`

All new filesystem backends (`JustBash.FS.NullFS`, `JustBash.FS.ReadOnlyFS`,
plus `GitFS`/`OverlayFS` from the Git integration) live under the new
`JustBash.FS.*` namespace.

### Running the migration

A single find-and-replace covers almost every caller:

```
s/JustBash\.Fs\.InMemoryFs/JustBash.FS.InMemoryFS/g
s/\bInMemoryFs\b/InMemoryFS/g
s/JustBash\.Fs\b/JustBash.FS/g
s/\bFs\b/FS/g
```

The compiler will flag any site that still references the old names (aliases,
struct patterns, function calls, typespecs).

### The one silent failure mode

Mount tuples embed the backend module as a plain atom:

```elixir
{"/data", JustBash.Fs.InMemoryFs, state}   # old
{"/data", JustBash.FS.InMemoryFS, state}   # new
```

A missed rename here compiles fine but fails at runtime with
`UndefinedFunctionError` when the mount is accessed. Grep for
`JustBash.Fs.` in your code to catch these.

### What did not change

- The `bash.fs` field access (field name is `:fs`, unchanged)
- `JustBash.new(fs:, files:, mounts:)` option keys
- `JustBash.exec/2`, `JustBash.new/1`, the `~b` sigil, the result map shape
- The mount-tuple shape (`{mountpoint, module, state}`)
- The `:context` option added in 0.3.0
