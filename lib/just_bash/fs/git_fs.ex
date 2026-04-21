defmodule JustBash.FS.GitFS do
  @moduledoc """
  A read-only VFS backend that mounts a git repository at a path.

  Backed by [exgit](https://github.com/ivarvong/exgit) — pure-Elixir git over
  smart HTTP v2, no `git` binary, no libgit2. Add it to your deps to use this
  backend:

      {:exgit, github: "ivarvong/exgit", branch: "main"}

  `GitFS` is **optional**: `just_bash` compiles and runs without `exgit`.
  Calling `GitFS.new/1` at runtime raises a clear error if `exgit` is absent.

  ## Usage

      # Mount a public repo — lazy clone fetches blobs on demand
      {:ok, fs} = FS.mount(FS.new(), "/repo", GitFS.new(url: "https://github.com/user/repo"))
      bash = JustBash.new(fs: fs)

      {r, _} = JustBash.exec(bash, "ls /repo")
      {r, _} = JustBash.exec(bash, "cat /repo/README.md")
      {r, _} = JustBash.exec(bash, "grep -r defmodule /repo/lib")

  ## Options for `new/1`

    * `:url` — repository URL (required)
    * `:ref` — branch, tag, or commit SHA to mount (default: `"HEAD"`)
    * `:auth` — an `Exgit.Credentials` value (default: none, public repos only)
    * `:eager` — when `true`, performs a full upfront clone (every blob
      in memory, no network after `new/1`). Default: `false`, which uses
      a partial clone (`filter: {:blob, :none}`) — one round trip pulls
      refs + commits + trees, and blobs are fetched on demand. `ls`,
      `stat`, and `exists?` are served from memory immediately after
      `new/1`; only `read_file` (or `materialize/1`) hits the network.
    * `:path` — local path to cache the clone on disk; omit to clone into
      memory only

  ## Processless — and what that implies for repeated reads

  `GitFS` is a plain struct: no processes, no ETS, no side effects.
  `JustBash.FS.Backend` callbacks receive the state and return results
  without threading an updated state back, which means any blob fetched
  during a `read_file` call is discarded after that call returns.

  In practice:

    * `ls`, `stat`, `exists?` — served entirely from memory after `new/1`,
      zero network.
    * `read_file` on a partial clone — fetches the blob every call.
      Re-reading the same file re-fetches it.

  For grep-heavy or multi-file workloads, call `materialize/1` once after
  `new/1` to pull every blob reachable from the ref into the struct up
  front. All subsequent `read_file` calls are in-memory.

  ## Credentials

  Pass any `Exgit.Credentials` value directly:

      GitFS.new(
        url: "https://github.com/org/private-repo",
        auth: Exgit.Credentials.GitHub.auth("ghp_...")
      )

      GitFS.new(
        url: "https://github.com/org/private-repo",
        auth: Exgit.Credentials.basic("user", "password")
      )

      GitFS.new(
        url: "https://github.com/org/private-repo",
        auth: Exgit.Credentials.bearer("token")
      )
  """

  @behaviour JustBash.FS.Backend

  @type t :: %__MODULE__{repo: term(), ref: String.t()}

  defstruct [:repo, :ref]

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Fetch all blobs reachable from the mounted ref into the in-memory store.

  After `materialize/1`, `read_file` is served entirely from memory — no
  network. Use this before grep-heavy or multi-file workloads where every
  file will be read at least once:

      state =
        GitFS.new(url: "https://github.com/user/repo", lazy: true)
        |> GitFS.materialize()

      {:ok, fs} = FS.mount(FS.new(), "/repo", state)

  `new/1` already prefetches commits and trees so `ls`/`stat` are in-memory
  from the start. `materialize/1` adds the blobs — the remaining layer that
  `read_file` would otherwise fetch on demand.
  """
  @spec materialize(t()) :: t()
  def materialize(%__MODULE__{repo: repo, ref: ref} = state) do
    {:ok, materialized} = Exgit.Repository.materialize(repo, ref)
    %{state | repo: materialized}
  end

  @doc """
  Clone a git repository and return a `GitFS` backend state.

  Uses a partial clone (`filter: {:blob, :none}`) by default: a single
  network round trip fetches refs + commits + trees, which is everything
  `ls`, `stat`, and `exists?` need. Blobs (file contents) are fetched
  lazily on `read_file`. Pass `eager: true` for a full upfront clone.

  Network and authentication failures are expected boundary conditions and
  returned as `{:error, reason}` — callers should handle them. See
  `new!/1` for a raise-on-failure variant.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    ensure_exgit!()

    url = Keyword.fetch!(opts, :url)
    ref = Keyword.get(opts, :ref, "HEAD")
    eager = Keyword.get(opts, :eager, false)
    auth = Keyword.get(opts, :auth)

    clone_opts =
      []
      |> then(&if eager, do: &1, else: [{:filter, {:blob, :none}} | &1])
      |> then(&if auth, do: [{:auth, auth} | &1], else: &1)
      |> maybe_add_path(opts)

    case Exgit.clone(url, clone_opts) do
      {:ok, repo} -> {:ok, %__MODULE__{repo: repo, ref: ref}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Like `new/1` but raises on clone or prefetch failure.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, state} -> state
      {:error, reason} -> raise "GitFS.new!/1 failed: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Backend callbacks — query ops
  # ---------------------------------------------------------------------------

  @impl true
  def exists?(%__MODULE__{} = state, path) do
    case stat(state, path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @impl true
  def stat(%__MODULE__{repo: repo, ref: ref}, path) do
    case Exgit.FS.stat(repo, ref, exgit_path(path)) do
      {:ok, exgit_stat, _repo} -> {:ok, to_backend_stat(exgit_stat)}
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def lstat(%__MODULE__{} = state, path), do: stat(state, path)

  @impl true
  def readdir(%__MODULE__{repo: repo, ref: ref}, path) do
    case Exgit.FS.ls(repo, ref, exgit_path(path)) do
      {:ok, entries, _repo} ->
        {:ok, Enum.map(entries, fn {_mode, name, _sha} -> name end)}

      {:error, reason} ->
        {:error, map_error(reason)}
    end
  end

  @impl true
  def read_file(%__MODULE__{repo: repo, ref: ref}, path) do
    case Exgit.FS.read_path(repo, ref, exgit_path(path)) do
      {:ok, {_mode, %Exgit.Object.Blob{data: data}}, _repo} -> {:ok, data}
      {:ok, {_mode, {:lfs_pointer, _}}, _repo} -> {:error, :enotsup}
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def readlink(%__MODULE__{}, _path), do: {:error, :einval}

  # ---------------------------------------------------------------------------
  # Backend callbacks — all writes refused (read-only)
  # ---------------------------------------------------------------------------

  @impl true
  def write_file(%__MODULE__{}, _path, _content, _opts), do: {:error, :erofs}
  @impl true
  def append_file(%__MODULE__{}, _path, _content), do: {:error, :erofs}
  @impl true
  def mkdir(%__MODULE__{}, _path, _opts), do: {:error, :erofs}
  @impl true
  def rm(%__MODULE__{}, _path, _opts), do: {:error, :erofs}
  @impl true
  def chmod(%__MODULE__{}, _path, _mode), do: {:error, :erofs}
  @impl true
  def symlink(%__MODULE__{}, _target, _link), do: {:error, :erofs}
  @impl true
  def link(%__MODULE__{}, _existing, _new), do: {:error, :erofs}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Converts a backend-relative path (starts with "/") to an exgit path
  # (relative, no leading slash). The root "/" becomes "".
  defp exgit_path("/"), do: ""
  defp exgit_path(path), do: String.trim_leading(path, "/")

  defp maybe_add_path(opts, kw) do
    case Keyword.get(kw, :path) do
      nil -> opts
      path -> [{:path, path} | opts]
    end
  end

  # Git tree entries don't carry mtimes — the value that would be correct
  # (the committer timestamp of the last commit to touch this path) costs
  # a full history walk. We return a fixed epoch so stat is deterministic:
  # identical inputs always produce identical output. Callers that need
  # real timestamps should use commit-walk APIs on the repo directly.
  @fixed_mtime ~U[1970-01-01 00:00:00Z]

  defp to_backend_stat(%{type: :tree}) do
    %{
      is_file: false,
      is_directory: true,
      is_symbolic_link: false,
      mode: 0o755,
      size: 0,
      mtime: @fixed_mtime
    }
  end

  defp to_backend_stat(%{type: :blob, mode: mode_str, size: size}) do
    %{
      is_file: true,
      is_directory: false,
      is_symbolic_link: false,
      mode: parse_mode(mode_str),
      size: size || 0,
      mtime: @fixed_mtime
    }
  end

  # Git mode strings are octal ("100644", "100755", "040000", "120000").
  defp parse_mode(mode_str) do
    case Integer.parse(mode_str, 8) do
      {mode, ""} -> mode
      _ -> 0o644
    end
  end

  # Map exgit errors to the POSIX atoms that JustBash.FS.Backend documents.
  # Unknown errors map to :eio (I/O error) rather than :enoent — an agent
  # encountering a real network or auth failure shouldn't be told the file
  # doesn't exist.
  defp map_error(:not_found), do: :enoent
  defp map_error(:not_a_blob), do: :eisdir
  defp map_error(:not_a_tree), do: :enotdir
  defp map_error(_), do: :eio

  defp ensure_exgit! do
    unless Code.ensure_loaded?(Exgit) do
      raise """
      JustBash.FS.GitFS requires the `exgit` package.

      Add to your mix.exs deps:

          {:exgit, github: "ivarvong/exgit", branch: "main"}

      Then run: mix deps.get
      """
    end
  end
end
