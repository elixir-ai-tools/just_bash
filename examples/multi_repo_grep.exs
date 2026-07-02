# Multi-repo grep on the just_bash + vfs + exgit stack.
#
# Code-mode in its simplest form: host code drives a sandboxed bash
# with command strings. The sandbox's filesystem is a %VFS{} mount
# table — just_bash's in-memory backend at "/", plus real GitHub
# repositories (cloned in pure Elixir, no git binary) mounted as exgit
# workspaces under /repos. Mounting is programmatic and incremental:
# each loop iteration below mounts one more repo, and the same grep
# sees a bigger world. Unmounting shrinks it back — and the repo
# handle still works host-side, where exgit's own streaming grep
# searches the clone without any mount at all.
#
# The sandbox is a value: JustBash.exec/2 returns {result, bash} and
# you thread the returned struct forward. Mount, exec, umount — all
# pure transformations of that value.
#
# Run it:
#
#     elixir examples/multi_repo_grep.exs
#
Mix.install([
  {:just_bash, github: "elixir-ai-tools/just_bash"},
  {:exgit, "~> 0.1.0"}
])

defmodule Shell do
  @doc "Run one command, print a transcript, return the threaded sandbox."
  def run(bash, command) do
    IO.puts("$ #{command}")
    {result, bash} = JustBash.exec(bash, command)

    IO.write(indent(result.stdout))
    if result.stderr != "", do: IO.write(indent(result.stderr))
    if result.exit_code != 0, do: IO.puts("  [exit code: #{result.exit_code}]")

    bash
  end

  defp indent(""), do: ""

  defp indent(out),
    do: out |> String.trim_trailing() |> String.replace(~r/^/m, "  ") |> Kernel.<>("\n")
end

# Ordered so the match list grows one repo at a time.
repos = [
  {"vfs", "https://github.com/ivarvong/vfs"},
  {"exgit", "https://github.com/ivarvong/exgit"},
  {"just_bash", "https://github.com/elixir-ai-tools/just_bash"},
  {"pyex", "https://github.com/ivarvong/pyex"}
]

# The question we grep for: every implementation of the VFS.Mountable
# protocol across the mounted repos. The /repos/*/lib glob expands
# across mount roots like any other directory (and skips each repo's
# tests and docs).
grep = "grep -rln 'defimpl VFS.Mountable, for:' /repos/*/lib"

# Mount one repo per iteration and re-run the same grep — the search
# space grows as the mount table does. (exgit finds its own impl: the
# library doing the mounting is itself mountable.)
#
# Exgit.clone/1 is a full clone: everything is fetched up front, so
# every later read is local — right for grep-the-whole-tree workloads.
# For reading a handful of files from a large repo, clone with
# `filter: {:blob, :none}` instead: blobs then fetch lazily on first
# read, and the mount table threads that cache forward.
{handles, bash} =
  Enum.map_reduce(repos, JustBash.new(), fn {name, url}, bash ->
    IO.puts("\n== mount #{name} (#{url})")
    {:ok, repo} = Exgit.clone(url)

    bash =
      bash
      |> JustBash.mount("/repos/#{name}", Exgit.Workspace.open(repo))
      |> Shell.run(grep)

    {{name, repo}, bash}
  end)

# Unmounting is just as programmatic: drop pyex from the table and the
# same grep no longer sees it.
IO.puts("\n== umount pyex")

bash
|> JustBash.umount("/repos/pyex")
|> Shell.run(grep)

# The mount is gone, but the clone isn't: the repo handle still works
# host-side. Exgit.FS.grep streams matches lazily straight off the
# object store — path-glob filtered, line-numbered, and consumer-
# driven: taking 2 halts the tree walk right there, and the walk never
# grows the cache.
IO.puts("\n== host-side: Exgit.FS.grep over the unmounted pyex clone (first 2 matches)")
{_name, pyex} = List.keyfind!(handles, "pyex", 0)

pyex
|> Exgit.FS.grep("HEAD", "defimpl VFS.Mountable, for:", path: "lib/**")
|> Enum.take(2)
|> Enum.each(fn match ->
  IO.puts("  #{match.path}:#{match.line_number}: #{String.trim(match.line)}")
end)
