if Code.ensure_loaded?(Exgit) do
  defmodule JustBash.Fs.GitFS do
    @moduledoc """
    A read-only filesystem backend backed by a remote Git repository via Exgit.

    Clones a repo into memory and serves its tree at a given ref. All mutating
    operations return `{:error, :erofs}`.

    ## Usage

        state = GitFS.new("https://github.com/org/repo")
        {:ok, fs} = Fs.mount(fs, "/repo", GitFS, state)

    ## Options

      * `:ref` — Git reference to serve (default: `"HEAD"`)
    """

    @behaviour JustBash.Fs.Backend

    @type t :: %__MODULE__{repo: Exgit.Repository.t(), ref: String.t()}

    defstruct [:repo, :ref]

    @spec new(String.t(), keyword()) :: t()
    def new(url, opts \\ []) do
      ref = Keyword.get(opts, :ref, "HEAD")
      {:ok, repo} = Exgit.clone(url)
      %__MODULE__{repo: repo, ref: ref}
    end

    # --- Read ops ---

    @impl true
    def exists?(%__MODULE__{} = state, "/") do
      state.repo != nil
    end

    def exists?(%__MODULE__{} = state, path) do
      Exgit.FS.exists?(state.repo, state.ref, to_git_path(path))
    end

    @impl true
    def stat(%__MODULE__{}, "/") do
      {:ok, root_dir_stat()}
    end

    def stat(%__MODULE__{} = state, path) do
      case Exgit.FS.stat(state.repo, state.ref, to_git_path(path)) do
        {:ok, info, _repo} -> {:ok, to_stat(info)}
        {:error, _} = err -> err
      end
    end

    @impl true
    def lstat(%__MODULE__{} = state, path), do: stat(state, path)

    @impl true
    def read_file(%__MODULE__{} = state, path) do
      case Exgit.FS.read_path(state.repo, state.ref, to_git_path(path)) do
        {:ok, {_mode, blob}, _repo} -> {:ok, blob.data}
        {:error, _} = err -> err
      end
    end

    @impl true
    def readdir(%__MODULE__{} = state, path) do
      git_path = if path == "/", do: "", else: to_git_path(path)

      case Exgit.FS.ls(state.repo, state.ref, git_path) do
        {:ok, entries, _repo} ->
          names = Enum.map(entries, fn {_mode, name, _sha} -> name end)
          {:ok, names}

        {:error, _} = err ->
          err
      end
    end

    @impl true
    def readlink(%__MODULE__{}, _path), do: {:error, :einval}

    # --- Mutating ops — all refused ---

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
    def symlink(%__MODULE__{}, _target, _link_path), do: {:error, :erofs}

    @impl true
    def link(%__MODULE__{}, _existing, _new), do: {:error, :erofs}

    # --- Helpers ---

    defp to_git_path("/" <> rest), do: rest
    defp to_git_path(path), do: path

    defp to_stat(%{type: type, mode: mode, size: size}) do
      %{
        is_file: type == :blob,
        is_directory: type == :tree,
        is_symbolic_link: false,
        mode: parse_mode(mode),
        size: size,
        mtime: ~U[2000-01-01 00:00:00Z]
      }
    end

    defp root_dir_stat do
      %{
        is_file: false,
        is_directory: true,
        is_symbolic_link: false,
        mode: 0o40755,
        size: 0,
        mtime: ~U[2000-01-01 00:00:00Z]
      }
    end

    defp parse_mode(mode) when is_binary(mode), do: String.to_integer(mode, 8)
  end
end
