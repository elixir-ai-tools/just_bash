# Stateful agent sessions on the just_bash + vfs + exgit stack.
#
# A session is a value. Its filesystem is a mount table: an in-memory
# backend at "/", real GitHub repositories (cloned in pure Elixir —
# no git binary, no disk, no container) mounted under /repos. Drive
# it with bash strings; thread the returned value forward. Forking a
# session is variable binding; rolling back is using the old binding.
#
# No helpers — every line is what a real caller writes. Each exec
# crash-asserts its exit code, so this deterministic transcript
# doubles as a smoke test of the whole stack.
#
#     elixir examples/agent_session.exs
#
Mix.install([
  {:just_bash, github: "elixir-ai-tools/just_bash"},
  {:exgit, "~> 0.1.0"}
])

repos = [
  {"vfs", "https://github.com/ivarvong/vfs"},
  {"exgit", "https://github.com/ivarvong/exgit"},
  {"just_bash", "https://github.com/elixir-ai-tools/just_bash"},
  {"pyex", "https://github.com/ivarvong/pyex"}
]

# Every VFS.Mountable implementation across whatever is mounted.
# /repos/*/lib globs across mount roots like ordinary directories.
grep = "grep -rln 'defimpl VFS.Mountable, for:' /repos/*/lib"

# ── Build the world: one more mount per iteration, same grep ────────
session =
  Enum.reduce(repos, JustBash.new(), fn {name, url}, session ->
    IO.puts("\n== mount #{name}\n$ #{grep}")
    {:ok, repo} = Exgit.clone(url)
    session = JustBash.mount(session, "/repos/#{name}", Exgit.Workspace.open(repo))

    {%{exit_code: 0} = result, session} = JustBash.exec(session, grep)
    IO.write(result.stdout)
    session
  end)

# ── State threads: one exec's writes are the next exec's world ──────
{%{exit_code: 0}, session} = JustBash.exec(session, "#{grep} > /work/matches.txt")
{%{exit_code: 0} = result, session} = JustBash.exec(session, "wc -l < /work/matches.txt")
IO.puts("\n== agent wrote /work/matches.txt: #{String.trim(result.stdout)} matches")

# ── Fork and roll back: sessions are values ─────────────────────────
checkpoint = session

{%{exit_code: 0}, session} = JustBash.exec(session, "rm /work/matches.txt")
{%{exit_code: 1}, _} = JustBash.exec(session, "cat /work/matches.txt")
{%{exit_code: 0}, _} = JustBash.exec(checkpoint, "cat /work/matches.txt")
IO.puts("== rm'd in the live session; the checkpoint still has it")

# ── Shrink the world ────────────────────────────────────────────────
IO.puts("\n== umount pyex\n$ #{grep}")
session = JustBash.umount(session, "/repos/pyex")

{%{exit_code: 0} = result, _session} = JustBash.exec(session, grep)
IO.write(result.stdout)
