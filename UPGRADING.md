# Upgrading

## 0.3 → 0.4: the vfs filesystem

`JustBash.new/1`, `exec/2`, `exec_file/2`, the `~b` sigil, `:context`,
and `JustBash.CLI` are unchanged. Bash scripts behave as before except
for the exact deltas below.

### Exact behavioral changes at the bash level

Every difference a script can observe, verified against the 0.3 sources:

1. **`>`, `>>`, `&>>`, `tee`, and `tee -a` now write through symlinks**
   (POSIX `O_TRUNC`/`O_APPEND` semantics): the target file receives the
   bytes and the link survives; writing through a dangling symlink
   creates the target. In 0.3, every one of these replaced the link
   itself with a regular file (`>> link` with target content plus the
   appended bytes, `tee -a link` with *only* the appended bytes,
   dropping the target's content). Writing or appending through a
   symlink loop now fails with "Too many levels of symbolic links". The
   same applies to any command that opens its output file (`mktemp`,
   `curl -o`, `wget`, ...), including `cp` onto a symlink. Rename-based
   writers keep their POSIX behavior of replacing the link itself: `mv`
   (rename semantics) and `sed -i` (GNU sed's documented "breaks
   symbolic links"), both matching bash and 0.3.
2. **`>>` preserves the target's mode.** 0.3 reset it to `0o644` on every
   append.
3. **`cat` on a symlink loop** prints
   `cat: PATH: Too many levels of symbolic links` and exits 1. 0.3 raised
   a `CaseClauseError` out of `JustBash.exec/2`.
4. **`mktemp`, `curl` (`-o`/`-D`), and `wget`** report filesystem write
   failures with conventional text ("File exists") where 0.3 interpolated
   the raw error atom ("eexist").
5. **`[[ a -nt b ]]` / `-ot`** compare mtimes chronologically
   (`DateTime.after?/2`). 0.3 used structural term comparison, which
   disagrees with wall-clock order across field boundaries.
6. **`ln` on a mount that doesn't support links** fails with
   `ln: failed to create ...: Operation not supported` and exit 1 (new
   situation — mounts didn't exist in 0.3; on the default backend, `ln`
   output is byte-identical to 0.3, including the directory-hard-link
   message).
7. **Writing through a regular file is now "Not a directory"** (exit 1),
   as POSIX path resolution requires. 0.3 stored the entry anyway —
   `echo hi > /m/j/2026/a.md` with `/m/j` a regular file exited 0, and the
   file was readable by path but absent from `ls`, globs, `find`, and
   `JustBash.FS.walk/3`. Every path-creating operation now refuses:
   `>`, `>>`, `&>`, `2>`, `touch`, `cp`, `mv`, `tee`, `ln`, `mkdir`,
   `mkdir -p`, and anything else that opens an output file.

   `mkdir -p` names the offending *ancestor* rather than the whole
   operand, matching GNU coreutils: `mkdir -p /m/j/2026` reports
   `mkdir: cannot create directory '/m/j': Not a directory`, while
   `mkdir` without `-p` still names the operand. `cp` reports a
   destination under a regular file as
   `cp: cannot stat 'PATH': Not a directory` (GNU stats the destination
   before opening it); `cannot create regular file` remains the wording
   for a merely missing parent.

   Paths resolve component-by-component on *both* sides, so a write
   *through a symlinked directory* lands on the target directory and is
   readable back at the path used — `echo hi > /link/a.md` then
   `cat /link/a.md` with `/link -> /real`. 0.3 stored an unreachable
   literal `/link/a.md` key. `mkdir -p` on a path that already exists as
   a *regular file* also fails now
   (`mkdir: cannot create directory 'PATH': File exists`, exit 1) instead
   of reporting success for a directory that does not exist, and so does
   `mkdir -p` on a dangling symlink.

   One deviation from POSIX remains: `..` is collapsed lexically before
   resolution, so `echo hi > /m/j/../k.md` writes `/m/k.md` and exits 0
   where bash reports `Not a directory`. Real resolution walks `..`
   through the directory it lands in; this does not admit unreachable
   state, so it stayed out of scope.

   A **command whose redirect cannot be opened no longer runs at all.**
   bash opens every redirect target before it forks the command, so
   `mkdir /made > /m/j/x` reports `bash: /m/j/x: Not a directory`, exits
   1, and leaves no `/made` behind — the side effects never happen, not
   just the output. 0.3 ran the command and applied the redirection to
   its result, so `result.stdout` still held `"hi\n"` for
   `echo hi > /m/j/a.md` and `/made` was created. This covers `>`, `>>`,
   `2>`, `&>`, `&>>`, a target that is a directory (`:eisdir`), and every
   construct a redirect can attach to: simple commands, functions,
   `for`/`while`/`until`, subshells, and groups.

   Because resolution now follows symlinks in every component, `stat/2`
   reports a symlinked directory *as* a directory — so **recursive commands
   decide descent with `lstat` instead**, which is what GNU's default `-P`
   does. `find`, `du`, `tree`, and `grep -r` list a symlink and stop there
   rather than walking through it; in 0.3 `find /d` with `/d/self -> /d`
   printed the subtree once per hop, and two such links never terminated.
   Consequences worth knowing: `find -type f` and `-type d` no longer match
   symlinks (`-type l` is now accepted and does), `grep -r` skips symlinks
   met while recursing but still follows one named as an operand, and
   `JustBash.FS.walk/3` yields a symlink with `type: :symlink` instead of
   its target's type. A symlink named directly on the command line is still
   followed, as it is under `-P`.

   Relatedly, `JustBash.new(files: ...)`, `JustBash.FS.new/1`, and
   `JustBash.FS.Memory.new/1` raise `ArgumentError` for a map that
   describes an impossible shape, such as
   `%{"/m/j" => "x", "/m/j/a.md" => "y"}` (0.3 accepted it and which entry
   survived depended on map iteration order) or one that collides with a
   directory the backend already holds, such as `%{"/" => "x"}`.
8. **A redirect target is created and truncated before the command runs**,
   as `open(2)` with `O_CREAT | O_TRUNC` does, so a command can no longer
   read the file it is redirecting into: `cat f > f` leaves `f` empty
   (0.3 rewrote `f` with its own contents), and so does any
   read-then-overwrite of the same path. `>>` opens with `O_APPEND`
   instead — an existing target keeps its contents *and* its mtime, so
   `true >> f` no longer touches `f` at all. A redirect target is also
   expanded exactly once now: `> $(gen-name)` runs `gen-name` once,
   before the command, rather than after it. When several redirections
   are listed and one cannot be opened, the ones to its left are still
   created or truncated and the ones to its right are never expanded —
   `echo hi > /bad > $(gen-name)` does not run `gen-name`.
9. **With additional mounts only** (a 0.4 capability): the parents of a
   mountpoint appear as synthetic directories, and foreign backends keep
   their own semantics — e.g. a plain `VFS.Memory` mount treats
   directories implicitly and refuses `rm` of an empty directory with
   "Is a directory", where the default backend removes it.

Everything else — every command's output text, exit codes, redirection,
globbing, conditionals, heredocs — is covered by the unchanged 3,700-test
suite plus the bash-comparison corpus, all passing on both sides of the
migration.

What changed is the filesystem underneath `bash.fs`. It is now a `%VFS{}`
mount table from the [vfs](https://hexdocs.pm/vfs) library, with
`JustBash.FS.Memory` (JustBash's in-memory backend: symlinks, hard links,
modes, mtimes) mounted at `/`. If your host-side code — custom commands,
test helpers — called `JustBash.Fs` / `JustBash.Fs.InMemoryFs` or reached
into `bash.fs.data`, it needs the mapping below.

### Module renames

Yes, the only visible difference in the first row is the case of the `s`.
0.3 shipped `Fs`; the project convention (shared with the `vfs` package —
`VFS`, never `Vfs`) fully uppercases acronyms, and the two spellings
cannot coexist as deprecated aliases: `Elixir.JustBash.Fs.beam` and
`Elixir.JustBash.FS.beam` are the same file on case-insensitive
filesystems (macOS, Windows). So 0.4 completes the rename in one step,
and `mix just_bash.audit` flags any survivor — don't proofread for the
case of an `s` by eye.

| Old (0.3) | New (0.4) |
|---|---|
| `JustBash.Fs` | `JustBash.FS` |
| `JustBash.Fs.InMemoryFs` | `JustBash.FS.Memory` (but call through `JustBash.FS` — `bash.fs` is a `%VFS{}`, not a bare backend) |

If you were on 0.3 locally, run `mix clean` once after updating — a stale
`_build` can hold both spellings' beams, which case-insensitive
filesystems silently conflate.

### Return shapes

Reads now return the updated filesystem as the last element — thread it
back into the struct you return, so lazy backends (a git mount fetching
blobs on demand) keep their caches:

| Old | New |
|---|---|
| `{:ok, content} = Fs.read_file(fs, p)` | `{:ok, content, fs} = FS.read_file(fs, p)` |
| `Fs.exists?(fs, p) #=> boolean` | `{exists?, fs} = FS.exists?(fs, p)` — **a tuple; don't use it as an `if` condition directly** |
| `{:ok, stat} = Fs.stat(fs, p)` | `{:ok, %VFS.Stat{}, fs} = FS.stat(fs, p)` |
| `{:ok, entries} = Fs.readdir(fs, p)` | `{:ok, entries, fs} = FS.readdir(fs, p)` |
| `{:ok, target} = Fs.readlink(fs, p)` | `{:ok, target, fs} = FS.readlink(fs, p)` |
| `{:error, :enoent}` | `{:error, %VFS.Error{kind: :enoent}}` — match on `:kind`; `FS.strerror/1` gives the conventional message text |

Mutations (`write_file`, `mkdir`, `rm`, `symlink`, `link`, `chmod`,
`append_file`, `cp`, `mv`) still return `{:ok, fs}`.

Two mutation semantics changed on the default backend: `FS.write_file/4`
and `FS.chmod/3` now follow symlinks to the final target, as
`append_file/3` always should have — 0.3's `Fs.write_file` replaced the
link with a regular file, and `Fs.chmod` set the mode on the link entry
itself. Note that `FS.link/3` creates a link-time copy, not a shared
inode: a later write through one name does not update the other (same
as 0.3).

### Stat fields

`%VFS.Stat{type, size, mtime, mode}` replaces the boolean map:

| Old | New |
|---|---|
| `stat.is_file` | `stat.type == :regular` |
| `stat.is_directory` | `stat.type == :directory` |
| `stat.is_symbolic_link` | `stat.type == :symlink` (only ever from `lstat`) |
| `stat.mode` | `stat.mode` — now `nil` on backends without modes; fall back explicitly when displaying |

### Option renames

| Old | New |
|---|---|
| `Fs.mkdir(fs, p, recursive: true)` | `FS.mkdir(fs, p, parents: true)` |
| `Fs.rm(fs, p, force: true)` | removed — match `{:error, %VFS.Error{kind: :enoent}}` at the call site |
| `Fs.get_all_paths(fs)` | removed — compose from `FS.walk(fs, "/", include_dirs: true)` |

### A migrated custom command

```elixir
# 0.3
def execute(bash, [path], _stdin) do
  resolved = JustBash.Fs.resolve_path(bash.cwd, path)

  case JustBash.Fs.read_file(bash.fs, resolved) do
    {:ok, content} ->
      {:ok, fs} = JustBash.Fs.write_file(bash.fs, resolved, String.upcase(content))
      {%{stdout: "", stderr: "", exit_code: 0}, %{bash | fs: fs}}

    {:error, :enoent} ->
      {%{stdout: "", stderr: "upcase: #{path}: No such file\n", exit_code: 1}, bash}
  end
end

# 0.4
def execute(bash, [path], _stdin) do
  resolved = JustBash.FS.resolve_path(bash.cwd, path)

  case JustBash.FS.read_file(bash.fs, resolved) do
    {:ok, content, fs} ->
      {:ok, fs} = JustBash.FS.write_file(fs, resolved, String.upcase(content))
      {%{stdout: "", stderr: "", exit_code: 0}, %{bash | fs: fs}}

    {:error, %VFS.Error{} = err} ->
      msg = "upcase: #{path}: #{JustBash.FS.strerror(err)}\n"
      {%{stdout: "", stderr: msg, exit_code: 1}, bash}
  end
end
```

### Auditing your code for silent breakage

Most legacy shapes **compile cleanly and misbehave at runtime**: a stale
`{:ok, content}` match silently falls through to your error clause, an
`{:error, :enoent}` clause silently never matches, and `FS.exists?/2` in
an `if` is a tuple — always truthy. Two lines of defense ship with 0.4:

**Static:** run the migration auditor over your own code (it scans for
all seven legacy shapes — `mix help just_bash.audit` has the rule
table):

```sh
mix just_bash.audit lib test
# path/file.ex:42 [stale_ok_tuple] matches {:ok, _} on FS.read_file — success is now {:ok, payload, fs}; ...
```

It exits non-zero on findings, so it can gate CI while you migrate.

**Runtime:** the two shapes that would otherwise be silently *ignored* —
`FS.mkdir(fs, p, recursive: true)` and `FS.rm(fs, p, force: true)` —
raise `ArgumentError` with a pointer here instead of doing the wrong
thing quietly.

### What you get for the churn

Any [`VFS.Mountable`](https://hexdocs.pm/vfs/VFS.Mountable.html) backend
now mounts into the environment and every bash command sees it:

```elixir
bash = JustBash.new()
bash = JustBash.mount(bash, "/mnt", VFS.Memory.new(%{"/data.csv" => "a,b\n"}))
{result, bash} = JustBash.exec(bash, "cat /mnt/data.csv")
```

See `test/showcase_test.exs` for a guided tour.
