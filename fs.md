# JustBash: Mountable Virtual Filesystem

**Status:** Design spec
**Target:** [`elixir-ai-tools/just_bash`](https://github.com/elixir-ai-tools/just_bash)
**Scope:** Replace the single hardcoded in-memory filesystem with a mount-table-based virtual filesystem that supports multiple pluggable backends rooted at arbitrary path prefixes.

---

## 1. Motivation

Today, `JustBash.Fs` claims in its moduledoc to be a "Filesystem behaviour," but it is not:

- It declares no `@behaviour` and no `@callback`s.
- It is a wall of `defdelegate ... to: InMemoryFs`.
- `JustBash.new/1` hardcodes `InMemoryFs.new()` at `lib/just_bash.ex:307`.
- The `%JustBash{}` struct holds a raw `%InMemoryFs{}`, and ~189 call sites across `lib/just_bash/commands/*` and the executor pattern-match on or call `InMemoryFs.*` directly, bypassing the facade.
- There is no way for a library caller to inject an alternate backend, let alone compose multiple.

This blocks real use cases for agent sandboxes: exposing a real (but scoped) project directory as `/workspace`, backing `/data` with S3 or a read-only snapshot, layering a copy-on-write overlay on top of a project, or enforcing a size quota on a writable scratch area — all while the rest of the shell still operates against a cheap in-memory FS.

The goal of this spec is to turn `JustBash.Fs` into a real virtual filesystem with a **mount table**: a routing layer that dispatches filesystem operations to pluggable backends based on longest-prefix mountpoint matching, while synthesizing mountpoints into directory listings so `ls /` sees `/data` even when nothing lives there in the root backend.

---

## 2. Goals and non-goals

### Goals

1. A real `JustBash.Fs.Backend` behaviour with explicit callbacks.
2. A mount table owned by `%JustBash.Fs{}` that routes ops to backends by longest-prefix match.
3. Synthetic visibility of mountpoints in `readdir`/`stat`/`exists?` regardless of what the underlying backend contains.
4. Cross-mount `cp` supported via read-from-A-write-to-B composition at the `Fs` level; cross-mount `mv` refused with `:exdev`.
5. Fallible backend ops: errors propagate as non-zero exit codes and stderr, using POSIX-atom error conventions already present in `InMemoryFs`.
6. Zero behavior change for users who do not register any mounts — the default is a single `/` mount of `InMemoryFs`, indistinguishable from today.
7. Migration path is staged so each step is independently mergeable and keeps the test suite green.

### Non-goals

- Concurrent / multi-process access semantics. The VFS remains single-owner and functionally updated.
- POSIX file locks, inotify, `fcntl`, `ioctl`, or any `/proc`-style synthetic filesystems.
- Quotas, ACLs beyond the existing `mode` field, or extended attributes.
- Mounting a backend at a non-absolute path. Mountpoints are always absolute, normalized.
- Per-mount chroot escape hardening beyond path normalization (backends are responsible for their own safety when they touch the real OS).
- Changing the `curl` / `wget` network sandbox or the custom-command model.

---

## 3. Terminology

- **Backend.** A module implementing `JustBash.Fs.Backend`. Operates in its own coordinate space, always rooted at `/`. Knows nothing about where it is mounted.
- **Backend state.** The opaque term a backend threads through its callbacks (e.g. `%InMemoryFs{}` for the in-memory backend). Functionally updated on every mutating op.
- **Mount.** A `{mountpoint, module, backend_state}` triple registered in the `Fs` struct.
- **Mountpoint.** A canonical absolute path where a backend is attached. Exactly one backend per mountpoint. The root `/` is always mounted.
- **Resolution.** The process of taking a user-facing absolute path and returning the `{module, backend_state, backend_relative_path}` triple that should handle it.
- **Shadowing.** When a mount is registered at a path where the parent backend already has content, the mount wins. The shadowed content is invisible until the mount is removed.

---

## 4. The `JustBash.Fs.Backend` behaviour

Backends are dumb. They operate on their own root-relative paths and have no knowledge of the mount table. All cross-backend concerns (cross-mount `cp`, synthetic mountpoint entries, longest-prefix routing) live in `JustBash.Fs`.

### 4.1 Return conventions

- Mutating ops return `{:ok, new_state} | {:error, reason}`.
- Query ops return `{:ok, value} | {:error, reason}` except `exists?/2`, which returns `boolean()`.
- `reason` is a POSIX-style atom. The set already in use by `InMemoryFs` is the baseline: `:enoent`, `:eisdir`, `:enotdir`, `:eloop`, `:einval`, `:eexist`, `:eacces`. Backends may introduce additional atoms; consumers must treat unknown reasons as generic I/O errors.
- Two additional reasons are introduced by this spec: `:exdev` (cross-device, used for `mv` across mounts) and `:erofs` (read-only filesystem, used by the read-only decorator backend).
- Errors propagate out through `Fs.*` unchanged. Commands translate them into stderr messages and non-zero exit codes, matching the way `InMemoryFs` errors are handled today.

### 4.2 Callbacks

```elixir
defmodule JustBash.Fs.Backend do
  @type state :: term()
  @type path :: String.t()
  @type reason :: atom()

  @type stat_result :: %{
          is_file: boolean(),
          is_directory: boolean(),
          is_symbolic_link: boolean(),
          mode: non_neg_integer(),
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type write_opts :: [append: boolean()]
  @type mkdir_opts :: [recursive: boolean()]
  @type rm_opts :: [recursive: boolean(), force: boolean()]

  @callback exists?(state, path) :: boolean()
  @callback stat(state, path) :: {:ok, stat_result} | {:error, reason}
  @callback lstat(state, path) :: {:ok, stat_result} | {:error, reason}

  @callback read_file(state, path) :: {:ok, binary} | {:error, reason}
  @callback write_file(state, path, binary, write_opts) :: {:ok, state} | {:error, reason}
  @callback append_file(state, path, binary) :: {:ok, state} | {:error, reason}

  @callback mkdir(state, path, mkdir_opts) :: {:ok, state} | {:error, reason}
  @callback readdir(state, path) :: {:ok, [String.t()]} | {:error, reason}
  @callback rm(state, path, rm_opts) :: {:ok, state} | {:error, reason}

  @callback chmod(state, path, non_neg_integer()) :: {:ok, state} | {:error, reason}

  @callback symlink(state, target :: path, link :: path) :: {:ok, state} | {:error, reason}
  @callback readlink(state, path) :: {:ok, path} | {:error, reason}
  @callback link(state, existing :: path, new :: path) :: {:ok, state} | {:error, reason}
end
```

### 4.3 Callbacks explicitly *not* on the backend

These live on `JustBash.Fs` because they are either pure path logic or need mount-table awareness:

- `normalize_path/1`, `resolve_path/2`, `dirname/1`, `basename/1` — pure path string manipulation, no state.
- `cp/3,4` — composed at the `Fs` level as `read_file` + `write_file` (plus `readdir`/`mkdir` for `-r`), so it transparently works across mount boundaries.
- `mv/3` — composed at the `Fs` level; same-mount path is a backend-native op (if the backend exposes one, via an optional callback we may add later), cross-mount path returns `{:error, :exdev}`.
- `get_all_paths/1` — if retained, iterates all mounts.

### 4.4 Path contract for backends

A backend receives **backend-relative absolute paths** — always starting with `/`, already normalized, with the mountpoint prefix stripped. Examples, assuming `S3Fs` is mounted at `/data`:

| User-facing path     | Backend receives |
|----------------------|-------------------|
| `/data`              | `/`               |
| `/data/foo.csv`      | `/foo.csv`        |
| `/data/sub/dir/x`    | `/sub/dir/x`      |

The backend never sees the string `/data`. It behaves exactly as if it were the entire filesystem rooted at `/`. This makes backends trivially composable and testable in isolation.

### 4.5 Symlinks

Symlinks are **within-backend only**. A symlink whose target would cross a mount boundary is either refused at creation (`:einval`) or, if the target path happens to cross a mount at read time, returns `:einval` on resolution. Cross-mount symlinks would require the backend to emit paths in the user-facing coordinate space, which breaks the "backends are dumb" contract. This limitation is documented; agents that need cross-mount references should use hard copies or the caller's custom-command facility.

Hard links (`link/3`) are always within-backend — POSIX already requires this, so no new rule.

---

## 5. The `JustBash.Fs` module

### 5.1 Struct

```elixir
defmodule JustBash.Fs do
  @type mount :: {mountpoint :: String.t(), module(), backend_state :: term()}
  @type t :: %__MODULE__{mounts: [mount()]}

  defstruct mounts: []
end
```

The mount list is ordered arbitrarily but resolution always selects by longest mountpoint string, so ordering does not affect correctness. The `/` mount is always present in any `Fs` struct returned by `new/1`.

### 5.2 Public API

```elixir
# Construction
Fs.new()                          # Fs with root `/` mounted to InMemoryFs.new()
Fs.new(files: %{...})             # As above, with initial files seeded into root
Fs.new(root: {module, state})     # Custom root backend

# Mount management
Fs.mount(fs, mountpoint, module, backend_state)  # {:ok, fs} | {:error, reason}
Fs.umount(fs, mountpoint)                        # {:ok, fs} | {:error, :enoent | :ebusy}
Fs.mounts(fs)                                    # [{mountpoint, module}]

# Pure path helpers (moved off InMemoryFs)
Fs.normalize_path(path)
Fs.resolve_path(base, path)
Fs.dirname(path)
Fs.basename(path)

# Filesystem ops — same surface as today, all now mount-aware
Fs.exists?(fs, path)
Fs.stat(fs, path)
Fs.lstat(fs, path)
Fs.read_file(fs, path)
Fs.write_file(fs, path, content, opts \\ [])
Fs.append_file(fs, path, content)
Fs.mkdir(fs, path, opts \\ [])
Fs.readdir(fs, path)
Fs.rm(fs, path, opts \\ [])
Fs.cp(fs, src, dest, opts \\ [])
Fs.mv(fs, src, dest)
Fs.chmod(fs, path, mode)
Fs.symlink(fs, target, link_path)
Fs.readlink(fs, path)
Fs.link(fs, existing_path, new_path)
Fs.get_all_paths(fs)
```

### 5.3 Mountpoint normalization

`mount/4` normalizes the mountpoint before storing:

1. Must be absolute (start with `/`). Non-absolute mountpoints return `{:error, :einval}`.
2. Run through `normalize_path/1` to collapse `.`, `..`, and repeated slashes.
3. Strip a trailing slash, except for `/` itself, which is stored as exactly `/`.
4. Must not already be registered. Duplicate mounts return `{:error, :eexist}`.

### 5.4 Longest-prefix resolution

For a user-facing path `P` (already normalized to absolute form):

```
resolve(fs, P) -> {module, backend_state, backend_relative_path, mount_index}
```

Algorithm:

1. Normalize `P`.
2. Find the mount whose mountpoint is the longest string such that `P == mountpoint` **or** `P` starts with `mountpoint <> "/"`. The `<> "/"` boundary check is what prevents `/datastore` from matching a `/data` mount.
3. Compute `backend_relative_path`:
   - If `P == mountpoint`, the backend path is `"/"`.
   - Otherwise, the backend path is `"/" <> String.trim_leading(P, mountpoint <> "/")`.
4. Return the matched mount's module and current state, plus the index of the mount in `fs.mounts` so writes can update that slot.

Resolution always succeeds because `/` is always mounted.

### 5.5 Dispatch and state threading

Query ops (`exists?`, `stat`, `lstat`, `read_file`, `readdir`, `readlink`, `get_all_paths`):

```
Fs.read_file(fs, path)
  -> {module, state, backend_path, _idx} = resolve(fs, path)
  -> module.read_file(state, backend_path)
```

Mutating ops thread new state back into the mount list:

```
Fs.write_file(fs, path, content, opts)
  -> {module, state, backend_path, idx} = resolve(fs, path)
  -> case module.write_file(state, backend_path, content, opts) do
       {:ok, new_state} -> {:ok, put_mount_state(fs, idx, new_state)}
       {:error, _} = err -> err
     end
```

`put_mount_state/3` is an internal helper that replaces the state term in the mount at the given index and returns the updated `%Fs{}`. This is the *only* way backend state is updated — commands never touch mount entries directly.

### 5.6 Mountpoint visibility — the core synthesis rule

Mountpoints are visible to the shell even when the parent backend knows nothing about them. Without this rule, `ls /` would omit `/data` whenever the root `InMemoryFs` has no `/data` entry of its own, and the mount would be invisible to the user.

**Rule.** Let `P` be a normalized absolute path. Define:

> **Child mounts of P** = the set of mounts whose mountpoint `M` satisfies `dirname(M) == P` and `M != "/"`.

Their basenames are "synthetic children" of `P`.

This rule is applied uniformly across three query ops:

1. **`readdir(fs, P)`** — Dispatch to the resolving backend. Take its returned entry list, union it with the basenames of child mounts of `P`, and deduplicate (child mounts shadow any identically-named backend entry). If the backend returned `{:error, :enoent}` but `P` has at least one child mount, return `{:ok, [child_mount_basenames]}` — i.e. a purely synthetic directory listing. This is what makes `ls /data/nested` work when `/data/nested/sub` is the only thing registered and `/data` itself has no entry at `/nested`.

2. **`stat(fs, P)`** and **`lstat(fs, P)`** — If `P` is itself a registered mountpoint, return a synthetic directory stat (`is_directory: true`, `mode: 0o755`, `size: 0`, `mtime: DateTime.utc_now()`) without consulting any backend. Otherwise, dispatch to the resolving backend. If the backend returns `{:error, :enoent}` but `P` has at least one child mount, return the same synthetic directory stat. Rationale: any ancestor directory of a mount must appear to exist, or `cd /data/nested` fails before you ever reach the mount.

3. **`exists?(fs, P)`** — True if `P` is a registered mountpoint, true if `P` has at least one child mount (transitively — any mount whose mountpoint starts with `P <> "/"` counts), otherwise dispatch to the resolving backend.

Synthetic stat values are deliberately minimal and stable. Agents that need richer metadata should stat something that actually exists inside a backend.

### 5.7 Cross-mount `cp`

`Fs.cp/4` is implemented at the `Fs` level, not by backends. The algorithm:

1. Resolve `src` and `dest` to their respective mounts.
2. If both resolve to the same mount and the same backend state slot, the op *could* be delegated to a backend-native `cp` for efficiency — but the spec does not require this. A read-then-write composition is always correct.
3. Otherwise:
   - For a file: `read_file(src)`, then `write_file(dest, content, [])`. Preserve mode by following up with `chmod(dest, src_mode)` when `src_mode` is known.
   - For a directory with `recursive: true`: `mkdir(dest, recursive: true)`, `readdir(src)`, recurse into each child. Symlinks inside the source directory are copied as symlinks if and only if the target resolves within the *source* backend; cross-backend symlink targets become `:einval` and abort the copy unless `force` is set, in which case they are skipped with a warning recorded on stderr by the calling command.
4. Any backend error aborts the op and propagates the first error, matching current `cp` semantics.

This gives transparent cross-mount copy "for free" — backends never need to know copies are happening across them.

### 5.8 `mv` and the `:exdev` rule

`Fs.mv/3` resolves `src` and `dest`:

- **Same mount** (same mountpoint, same mount index): dispatch to a single backend operation. If the backend does not expose a native `mv`, `Fs` falls back to `cp` + `rm` within that one backend. Either way, no cross-mount traversal.
- **Different mounts**: return `{:error, :exdev}`. Commands translate this to the familiar `mv: cannot move '<src>' to '<dest>': Invalid cross-device link`. Users who want cross-mount moves use `cp` followed by `rm`.

Rationale: Linux does exactly this for real filesystems, the atom is already standard, and it avoids the ambiguity of partial moves when a multi-step cross-backend op fails halfway through.

### 5.9 Operations that span mounts

- **`rm -rf /`** — iterate all mounts, call `rm(state, "/", recursive: true, force: true)` on each. The root `/` mount is never removed from the mount list; only its contents are cleared (by whatever the backend does in response to `rm /` with recursive+force). Non-root mounts are left intact: `rm -rf /` does not unmount anything, it just empties each backend.
- **`get_all_paths/1`** — if retained, iterate every mount, prepend the mountpoint to each returned path (with `/` special-cased), and concatenate.
- **`find /` without `-xdev`** — naturally traverses through child mounts because `readdir` synthesizes them. No special logic in the `find` command.
- **A `-xdev` flag on `find`** is out of scope for this spec but trivially implementable later: the `find` command can track which mount index the traversal started in and refuse to descend into a subdirectory whose resolution returns a different index.

### 5.10 Shadowing

If the root `InMemoryFs` already contains `/data/old.txt` and a caller then mounts a backend at `/data`:

- `ls /data` no longer shows `old.txt`. It shows whatever the new `/data` backend returns at `/`.
- `cat /data/old.txt` returns whatever the new backend says — probably `:enoent`.
- `Fs.umount(fs, "/data")` restores visibility of `/data/old.txt`, because the original root backend state was never mutated.

This matches Linux mount semantics and is documented as intentional.

---

## 6. `JustBash.new/1` integration

`JustBash.new/1` gains a new option and keeps full backward compatibility:

```elixir
JustBash.new()
# => %JustBash{fs: Fs with root=InMemoryFs, ...}

JustBash.new(files: %{"/a.txt" => "hi"})
# => unchanged — seeds the root InMemoryFs

JustBash.new(fs: some_prebuilt_fs_struct)
# => use the caller's Fs as-is

JustBash.new(mounts: [
  {"/data", MyApp.S3Fs, [bucket: "agent-data"]},
  {"/readonly", JustBash.Fs.ReadOnlyFs, inner: snapshot_fs}
])
# => root InMemoryFs + additional mounts; each mount spec's third element
#    is passed to the backend's `new/1`
```

Precedence: if `fs:` is given, `files:` and `mounts:` are rejected with a clear error — the caller is taking full responsibility for the mount table. If `fs:` is absent, `files:` seeds the root and `mounts:` adds additional mounts on top.

---

## 7. Reference backends shipped in-tree

Three backends live in the repo so callers have working examples and the test suite can exercise multi-backend scenarios.

### 7.1 `JustBash.Fs.InMemoryFs` — default root

Exactly today's implementation, minimally adapted:

- Implements the `JustBash.Fs.Backend` behaviour formally.
- `resolve_path`, `normalize_path`, `dirname`, `basename` move **out** of this module and up to `JustBash.Fs` (they are pure path logic and must be shared across backends). All internal callers of the old functions inside `InMemoryFs` are redirected to `JustBash.Fs.*`.
- Public API outside the behaviour is deprecated but preserved for one release with `@deprecated` warnings, to ease the migration of any external callers.

No behavior changes in the common path. The existing test suite for `InMemoryFs` continues to pass unchanged.

### 7.2 `JustBash.Fs.ReadOnlyFs` — decorator

A backend that wraps another backend and rejects all mutating operations with `{:error, :erofs}`.

```elixir
ro = JustBash.Fs.ReadOnlyFs.new(inner: {JustBash.Fs.InMemoryFs, some_state})
Fs.mount(fs, "/snapshot", JustBash.Fs.ReadOnlyFs, ro)
```

Reads pass through to `inner`. Writes (`write_file`, `append_file`, `mkdir`, `rm`, `chmod`, `symlink`, `link`) return `:erofs` without touching the inner state. Useful for exposing immutable snapshots to an agent.

Approximately 50 lines. Doubles as the proof that the behaviour contract actually works for non-trivial backends.

### 7.3 `JustBash.Fs.NullFs` — test fixture

A backend whose entire state is `:unit`, which returns `:enoent` for every query and `{:ok, :unit}` for every mutation (i.e. a /dev/null-style sink). Used in the test suite to verify mount-table mechanics without any real storage — it makes synthetic-mountpoint visibility tests deterministic.

Not documented as a public API; lives under `test/support/`.

---

## 8. Error semantics

| Atom      | Meaning                                                        | Where introduced by this spec              |
|-----------|----------------------------------------------------------------|---------------------------------------------|
| `:enoent` | Path does not exist                                            | (existing)                                  |
| `:eisdir` | Path is a directory, op expected a file                        | (existing)                                  |
| `:enotdir`| Path is not a directory, op expected one                       | (existing)                                  |
| `:eloop`  | Symlink loop                                                   | (existing)                                  |
| `:einval` | Invalid argument (bad path, cross-mount symlink, etc.)         | (existing, expanded)                        |
| `:eexist` | Already exists                                                 | (existing; also used for duplicate mount)   |
| `:eacces` | Permission denied                                              | (existing)                                  |
| `:exdev`  | Cross-device link — `mv` across mounts                         | **new**                                     |
| `:erofs`  | Read-only filesystem — mutation against a read-only backend    | **new**                                     |
| `:ebusy`  | Mount point is in use — `umount` of a mount that still has active refs or is the root | **new** (conservative; see §11) |

Commands map these atoms to stderr messages using the existing error-formatting helpers, extended to cover the two new atoms.

---

## 9. Migration plan

The migration is staged so every PR is independently mergeable and leaves the test suite green.

### PR 1 — facade migration, zero behavior change

**Goal:** Route every filesystem call site in the codebase through `JustBash.Fs.*`, so there is exactly one choke point when the mount table lands.

- Grep every `InMemoryFs.*` call outside `lib/just_bash/fs/` and rewrite it to `JustBash.Fs.*`. There are ~189 such call sites across the executor, the expansion layer, and every command under `lib/just_bash/commands/`.
- Move `normalize_path`, `resolve_path`, `dirname`, `basename` from `InMemoryFs` into `JustBash.Fs` as plain module functions. Internal callers in `InMemoryFs` are updated to call them via `JustBash.Fs`. No public-facing name changes.
- Any pattern match on `%InMemoryFs{}` inside commands is loosened to `%JustBash.Fs{}` (or simply `fs` with no struct match).
- `JustBash.Fs` remains a thin passthrough — it still delegates to `InMemoryFs` for everything. No struct change yet.

**Definition of done:** full test suite passes; no remaining direct `InMemoryFs.*` reference outside `lib/just_bash/fs/`.

### PR 2 — introduce the behaviour and the `Fs` struct

**Goal:** Define the real behaviour, turn `Fs` into a struct with a mount list, wire `InMemoryFs` as the sole backend implementation.

- Create `JustBash.Fs.Backend` with the callbacks from §4.
- `InMemoryFs` formally declares `@behaviour JustBash.Fs.Backend` and implements each callback. The implementations are thin wrappers around the existing functions.
- `JustBash.Fs` becomes a real struct: `%Fs{mounts: [{"/", InMemoryFs, %InMemoryFs{}}]}`.
- Every `Fs.*` function now resolves through `resolve/2`, which in this PR trivially returns the single root mount. Dispatch goes `module.foo(state, path)`. Mutating ops replace the state in slot 0 of `mounts`.
- `%JustBash{fs: ...}` now holds a `%JustBash.Fs{}` instead of a `%InMemoryFs{}`. `JustBash.new/1` constructs the single-mount `Fs` struct. `files:` option still works, now by seeding the root mount.

**Definition of done:** full test suite passes; `%JustBash{}` no longer exposes `%InMemoryFs{}` directly; `Fs` is a real struct.

### PR 3 — the actual mount feature

**Goal:** Longest-prefix routing, synthetic mountpoints, cross-mount `cp`, `mv` refusal, and the public `mount`/`umount` API.

- Implement `resolve/2` per §5.4 with longest-prefix matching and the `<> "/"` boundary check.
- Implement §5.6 synthetic mountpoint visibility in `readdir`, `stat`, `lstat`, and `exists?`.
- Implement `Fs.cp/4` per §5.7 at the `Fs` level, composing `read_file` + `write_file` (+ `readdir`/`mkdir` for recursion). Remove `InMemoryFs.cp` from the behaviour surface; it becomes a private helper inside the backend module only if it is still needed for same-backend efficiency.
- Implement `Fs.mv/3` per §5.8 with the same-mount vs. cross-mount branch.
- Implement `Fs.mount/4` and `Fs.umount/2` per §5.2 and §5.3.
- Expose `fs:` and `mounts:` options on `JustBash.new/1` per §6.
- Ship `JustBash.Fs.ReadOnlyFs` in `lib/just_bash/fs/read_only_fs.ex`.
- Ship `JustBash.Fs.NullFs` in `test/support/null_fs.ex`.
- Add test coverage (see §10).

**Definition of done:** full test suite plus new mount-specific tests pass; documented example in the README shows `ls /` listing both `/tmp` and `/data` when only `/data` is mounted non-trivially.

---

## 10. Test plan

New tests live under `test/just_bash/fs/mount_test.exs` and exercise the mount layer end-to-end through `JustBash.exec/2`, not just the `Fs` API, so regressions in command wiring are caught.

### 10.1 Routing

- `ls /tmp` with only `/` mounted → dispatches to root, never touches mount-table lookup beyond the root entry.
- `ls /data` with `/data` mounted to `NullFs` → dispatches to `NullFs` with path `/`.
- `ls /data/sub` with `/data` mounted → dispatches to `/data` backend with path `/sub`.
- `ls /datastore` with `/data` mounted to `NullFs` and `/datastore` unmounted → routes to `/`, not to `/data`. (Boundary check.)
- Nested: `/data` and `/data/cache` both mounted → `ls /data/cache/x` routes to `/data/cache`, `ls /data/x` routes to `/data`.

### 10.2 Synthetic visibility

- `ls /` with a completely empty root `InMemoryFs` and `/data` mounted → output contains exactly `data`.
- `ls /` with root containing `tmp`, `home` and `/data` mounted → output is the union `data home tmp`.
- `ls /` with root containing a real `data` entry and `/data` mounted (shadow case) → output contains `data` exactly once.
- `stat /data` with `/data` mounted but backend `/` empty → reports `is_directory: true`.
- `stat /data/nested` where `/data/nested/sub` is the only mount and the backend at `/` knows nothing → reports `is_directory: true` (synthetic ancestor).
- `cd /data/nested && pwd` in the same scenario → succeeds.
- `[ -e /data ]` → exit 0 even when the resolving backend has no entry.

### 10.3 Cross-mount operations

- `cp /tmp/a.txt /data/a.txt` across two different backends → file appears in `/data` backend, file remains in `/tmp`.
- `cp -r /project /data/backup` across backends → recursive copy succeeds; file modes preserved where `stat` reports them.
- `mv /tmp/a.txt /data/a.txt` across backends → fails with stderr matching `cross-device link` and exit code 1. Source file unchanged.
- `mv /data/a.txt /data/b.txt` within one mount → succeeds.

### 10.4 Error propagation

- `cat /data/missing.txt` on a backend that returns `{:error, :enoent}` → stderr matches `No such file or directory`, exit 1.
- `echo x > /snapshot/new.txt` when `/snapshot` is a `ReadOnlyFs` mount → stderr matches `Read-only file system`, exit 1.
- Backend returning an unknown error atom → command emits a generic I/O error, exit 1, never crashes the shell.

### 10.5 Mount lifecycle

- `Fs.mount` with a non-absolute mountpoint → `{:error, :einval}`.
- `Fs.mount` at an already-mounted point → `{:error, :eexist}`.
- `Fs.umount` of `/` → `{:error, :ebusy}`.
- `Fs.umount` of a mount with shadowed content → mount removed, shadowed content visible again.
- `Fs.mounts` lists all current mounts in a stable order.

### 10.6 Backward compatibility

- Every existing test in `test/just_bash/` passes unchanged after PR 3 lands. This is the non-negotiable gate for each PR in the migration.

---

## 11. Open questions

These are called out so future work can resolve them; they are not blockers for the initial implementation.

1. **`:ebusy` semantics for `umount`.** The spec reserves `:ebusy` for umount of `/` and leaves the door open for refusing umount of a mount whose children (nested mounts) are still registered. Initial implementation refuses umount of `/` only; nested-child `:ebusy` can be added later without breaking callers.
2. **Backend-native `cp` fast path.** §5.7 permits but does not require backends to expose an efficient same-backend `cp`. If profiling shows read+write composition is a bottleneck for in-memory ops, a separate optional callback `copy_internal/3` can be added without changing the public contract.
3. **Symlink resolution across mount boundaries.** Currently refused with `:einval`. A future extension could allow absolute-path symlinks to resolve through the mount table, but only at read time — backends would still never emit user-facing paths. Deferred until a concrete use case appears.
4. **`find -xdev` and similar mount-aware flags.** Out of scope here; the spec notes it is trivially implementable on top of `resolve/2` returning a stable mount index.
5. **Concurrent mount mutation.** The VFS is single-owner and functionally updated, same as today. Any future GenServer-fronted variant would wrap `JustBash.Fs` without changing this spec.
