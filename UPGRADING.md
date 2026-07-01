# Upgrading

## 0.3 → 0.4: the vfs filesystem

Bash scripts are unaffected: every command, redirection, glob, and
conditional behaves as before. `JustBash.new/1`, `exec/2`, `exec_file/2`,
the `~b` sigil, `:context`, and `JustBash.CLI` are unchanged.

What changed is the filesystem underneath `bash.fs`. It is now a `%VFS{}`
mount table from the [vfs](https://hexdocs.pm/vfs) library, with
`JustBash.FS.Memory` (JustBash's in-memory backend: symlinks, hard links,
modes, mtimes) mounted at `/`. If your host-side code — custom commands,
test helpers — called `JustBash.Fs` / `JustBash.Fs.InMemoryFs` or reached
into `bash.fs.data`, it needs the mapping below.

### Module renames

| Old | New |
|---|---|
| `JustBash.Fs` | `JustBash.FS` |
| `JustBash.Fs.InMemoryFs` | `JustBash.FS.Memory` (but call through `JustBash.FS` — `bash.fs` is a `%VFS{}`, not a bare backend) |

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

### What you get for the churn

Any [`VFS.Mountable`](https://hexdocs.pm/vfs/VFS.Mountable.html) backend
now mounts into the environment and every bash command sees it:

```elixir
bash = JustBash.new()
bash = JustBash.mount(bash, "/mnt", VFS.Memory.new(%{"/data.csv" => "a,b\n"}))
{result, bash} = JustBash.exec(bash, "cat /mnt/data.csv")
```

See `test/showcase_test.exs` for a guided tour.
