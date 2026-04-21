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
    * `:lazy` — when `true` (default), fetches refs only and pulls blobs
      on demand; set `false` for a full upfront clone
    * `:path` — local path to cache the clone on disk; omit to clone into
      memory only

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

  ## Processless

  `GitFS` is a plain struct — no processes, no ETS, no side effects. `new/1`
  clones lazily and prefetches commits + trees so `ls`, `stat`, and `exists?`
  are served from memory. Blobs remain lazy: each `read_file` call fetches
  the blob on demand and discards the updated repo struct, so repeated reads
  of the same file re-fetch. Call `materialize/1` before grep-heavy workloads
  to pull all blobs into the struct up front.
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
  Clone (or open) a git repository and return a `GitFS` backend state.

  The repository is cloned lazily by default: only refs are fetched on startup;
  blobs are pulled on demand and cached in the agent. Pass `lazy: false` for
  a full upfront clone.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    ensure_exgit!()

    url = Keyword.fetch!(opts, :url)
    ref = Keyword.get(opts, :ref, "HEAD")
    lazy = Keyword.get(opts, :lazy, true)
    auth = Keyword.get(opts, :auth)

    clone_opts =
      []
      |> then(&if lazy, do: [{:lazy, true} | &1], else: &1)
      |> then(&if auth, do: [{:auth, auth} | &1], else: &1)
      |> maybe_add_path(opts)

    {:ok, repo} = Exgit.clone(url, clone_opts)
    # Prefetch commits + trees so ls/stat/exists? are served from the
    # in-memory object store. Blobs remain lazy — fetched on read_file.
    {:ok, repo} = Exgit.FS.prefetch(repo, ref)

    %__MODULE__{repo: repo, ref: ref}
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

  # Runs `fun.(repo)` inside an Agent.get_and_update, threading the returned
  # repository struct back into the agent on success so lazy-fetched blobs
  # accumulate in the cache across calls.
  #
  # fun must return one of:
  #   {:ok, result, new_repo}   — success, threads new_repo forward
  #   {:error, reason}          — failure, keeps current repo unchanged
  #   {:error, reason, new_repo} — failure with repo update (e.g. LFS pointer)
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

  defp to_backend_stat(%{type: :tree}) do
    %{
      is_file: false,
      is_directory: true,
      is_symbolic_link: false,
      mode: 0o755,
      size: 0,
      mtime: DateTime.utc_now()
    }
  end

  defp to_backend_stat(%{type: :blob, mode: mode_str, size: size}) do
    %{
      is_file: true,
      is_directory: false,
      is_symbolic_link: false,
      mode: parse_mode(mode_str),
      size: size || 0,
      mtime: DateTime.utc_now()
    }
  end

  # Git mode strings are octal ("100644", "100755", "040000", "120000").
  defp parse_mode(mode_str) do
    case Integer.parse(mode_str, 8) do
      {mode, ""} -> mode
      _ -> 0o644
    end
  end

  defp map_error(:not_found), do: :enoent
  defp map_error(:not_a_blob), do: :eisdir
  defp map_error(_), do: :enoent

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
