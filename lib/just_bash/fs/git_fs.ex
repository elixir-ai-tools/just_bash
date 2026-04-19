if Code.ensure_loaded?(Exgit) do
  defmodule JustBash.Fs.GitFS do
    @moduledoc """
    A filesystem backend backed by a remote Git repository via Exgit.

    Clones a repo into memory and serves its tree. By default the mount is
    read-only (`:erofs` on writes). Pass `writable: true` to enable writes
    that modify the in-memory git tree.

    ## Usage

        # Read-only (default)
        state = GitFS.new("https://github.com/org/repo")
        {:ok, fs} = Fs.mount(fs, "/repo", GitFS, state)

        # Read-write
        state = GitFS.new("https://github.com/org/repo", writable: true)
        {:ok, fs} = Fs.mount(fs, "/repo", GitFS, state)

    ## Options

      * `:ref` — Git reference to serve (default: `"HEAD"`)
      * `:writable` — allow mutations (default: `false`)
    """

    @behaviour JustBash.Fs.Backend

    alias Exgit.Object.Commit
    alias Exgit.Object.Tree
    alias Exgit.ObjectStore

    @type t :: %__MODULE__{
            repo: Exgit.Repository.t(),
            ref: String.t(),
            tree: binary() | nil,
            writable: boolean(),
            url: String.t() | nil,
            parent_commit: binary() | nil
          }

    defstruct [:repo, :ref, :tree, :url, :parent_commit, writable: false]

    @spec new(String.t(), keyword()) :: t()
    def new(url, opts \\ []) do
      ref = Keyword.get(opts, :ref, "HEAD")
      writable = Keyword.get(opts, :writable, false)
      {:ok, repo} = Exgit.clone(url)

      {tree, parent_commit} = resolve_initial_tree_and_commit(repo, ref)

      %__MODULE__{
        repo: repo,
        ref: ref,
        tree: tree,
        writable: writable,
        url: url,
        parent_commit: parent_commit
      }
    end

    # --- Read ops ---

    @impl true
    def exists?(%__MODULE__{tree: nil}, _path), do: false

    def exists?(%__MODULE__{} = s, "/"), do: s.tree != nil

    def exists?(%__MODULE__{} = s, path) do
      Exgit.FS.exists?(s.repo, reference(s), to_git_path(path))
    end

    @impl true
    def stat(%__MODULE__{}, "/") do
      {:ok, dir_stat()}
    end

    def stat(%__MODULE__{} = s, path) do
      case Exgit.FS.stat(s.repo, reference(s), to_git_path(path)) do
        {:ok, info, _repo} -> {:ok, to_stat(info)}
        {:error, :not_found} -> {:error, :enoent}
        {:error, _} = err -> err
      end
    end

    @impl true
    def lstat(%__MODULE__{} = s, path), do: stat(s, path)

    @impl true
    def read_file(%__MODULE__{} = s, path) do
      case Exgit.FS.read_path(s.repo, reference(s), to_git_path(path)) do
        {:ok, {_mode, blob}, _repo} -> {:ok, blob.data}
        {:error, :not_found} -> {:error, :enoent}
        {:error, _} = err -> err
      end
    end

    @impl true
    def readdir(%__MODULE__{} = s, path) do
      git_path = if path == "/", do: "", else: to_git_path(path)

      case Exgit.FS.ls(s.repo, reference(s), git_path) do
        {:ok, entries, _repo} ->
          {:ok, Enum.map(entries, fn {_mode, name, _sha} -> name end)}

        {:error, :not_found} ->
          {:error, :enoent}

        {:error, :not_a_tree} ->
          {:error, :enotdir}

        {:error, _} = err ->
          err
      end
    end

    @impl true
    def readlink(%__MODULE__{}, _path), do: {:error, :einval}

    # --- Write ops ---

    @impl true
    def write_file(%__MODULE__{writable: false}, _path, _content, _opts), do: {:error, :erofs}

    def write_file(%__MODULE__{} = s, path, content, opts) do
      mode = opts |> Keyword.get(:mode, 0o644) |> to_git_mode()
      git_path = to_git_path(path)

      case Exgit.FS.write_path(s.repo, reference(s), git_path, content, mode: mode) do
        {:ok, new_tree, repo} ->
          {:ok, %{s | repo: repo, tree: new_tree}}

        {:error, _} = err ->
          err
      end
    end

    @impl true
    def append_file(%__MODULE__{writable: false}, _path, _content), do: {:error, :erofs}

    def append_file(%__MODULE__{} = s, path, content) do
      case read_file(s, path) do
        {:ok, existing} -> write_file(s, path, existing <> content, [])
        {:error, _} = err -> err
      end
    end

    @impl true
    def mkdir(%__MODULE__{writable: false}, _path, _opts), do: {:error, :erofs}

    def mkdir(%__MODULE__{} = s, path, opts) do
      recursive = Keyword.get(opts, :recursive, false)

      if exists?(s, path) do
        {:error, :eexist}
      else
        if recursive do
          do_mkdir_recursive(s, path)
        else
          parent = Path.dirname(path)

          if parent == "/" or exists?(s, parent) do
            write_file(s, path <> "/.gitkeep", "", [])
          else
            {:error, :enoent}
          end
        end
      end
    end

    @impl true
    def rm(%__MODULE__{writable: false}, _path, _opts), do: {:error, :erofs}

    def rm(%__MODULE__{} = s, path, opts) do
      recursive = Keyword.get(opts, :recursive, false)
      force = Keyword.get(opts, :force, false)

      case stat(s, path) do
        {:ok, %{is_directory: true}} when not recursive ->
          {:error, :eisdir}

        {:ok, _info} ->
          delete_path(s, to_git_path(path))

        {:error, :enoent} when force ->
          {:ok, s}

        {:error, _} = err ->
          err
      end
    end

    @impl true
    def chmod(%__MODULE__{writable: false}, _path, _mode), do: {:error, :erofs}

    def chmod(%__MODULE__{} = s, path, mode) do
      case read_file(s, path) do
        {:ok, content} -> write_file(s, path, content, mode: mode)
        {:error, _} = err -> err
      end
    end

    @impl true
    def symlink(%__MODULE__{writable: false}, _target, _link_path), do: {:error, :erofs}

    def symlink(%__MODULE__{} = s, target, link_path) do
      git_path = to_git_path(link_path)

      case Exgit.FS.write_path(s.repo, reference(s), git_path, target, mode: "120000") do
        {:ok, new_tree, repo} -> {:ok, %{s | repo: repo, tree: new_tree}}
        {:error, _} = err -> err
      end
    end

    @impl true
    def link(%__MODULE__{writable: false}, _existing, _new), do: {:error, :erofs}

    def link(%__MODULE__{} = s, existing, new_path) do
      case read_file(s, existing) do
        {:ok, content} -> write_file(s, new_path, content, [])
        {:error, _} = err -> err
      end
    end

    # --- Tree deletion ---

    defp delete_path(%__MODULE__{} = s, git_path) do
      segments = String.split(git_path, "/", trim: true)
      tree_sha = s.tree

      case remove_from_tree(s.repo, tree_sha, segments) do
        {:ok, new_tree_sha, repo} ->
          {:ok, %{s | repo: repo, tree: new_tree_sha}}

        {:error, _} = err ->
          err
      end
    end

    defp remove_from_tree(repo, tree_sha, [name]) do
      case ObjectStore.get(repo.object_store, tree_sha) do
        {:ok, %Tree{entries: entries}} ->
          new_entries = Enum.reject(entries, fn {_, n, _} -> n == name end)

          if length(new_entries) == length(entries) do
            {:error, :enoent}
          else
            new_tree = Tree.new(new_entries)
            {:ok, sha, store} = ObjectStore.put(repo.object_store, new_tree)
            {:ok, sha, %{repo | object_store: store}}
          end

        {:error, _} = err ->
          err
      end
    end

    defp remove_from_tree(repo, tree_sha, [dir | rest]) do
      with {:ok, %Tree{entries: entries}} <- ObjectStore.get(repo.object_store, tree_sha),
           {_, _, child_sha} <- find_dir_entry(entries, dir),
           {:ok, new_child_sha, repo} <- remove_from_tree(repo, child_sha, rest) do
        other = Enum.reject(entries, fn {_, n, _} -> n == dir end)
        rebuild_parent_tree(repo, other, dir, new_child_sha)
      else
        nil -> {:error, :enoent}
        {:error, _} = err -> err
      end
    end

    # --- Helpers ---

    defp find_dir_entry(entries, dir) do
      Enum.find(entries, fn {m, n, _} -> n == dir and m == "40000" end)
    end

    defp rebuild_parent_tree(repo, other_entries, dir, new_child_sha) do
      new_entries =
        case ObjectStore.get(repo.object_store, new_child_sha) do
          {:ok, %Tree{entries: []}} -> other_entries
          _ -> other_entries ++ [{"40000", dir, new_child_sha}]
        end

      new_tree = Tree.new(new_entries)
      {:ok, sha, store} = ObjectStore.put(repo.object_store, new_tree)
      {:ok, sha, %{repo | object_store: store}}
    end

    defp reference(%__MODULE__{tree: nil, ref: ref}), do: ref
    defp reference(%__MODULE__{tree: tree}), do: tree

    defp resolve_initial_tree_and_commit(repo, ref) do
      case Exgit.RefStore.resolve(repo.ref_store, ref) do
        {:ok, commit_sha} ->
          case ObjectStore.get(repo.object_store, commit_sha) do
            {:ok, %Commit{} = c} -> {Commit.tree(c), commit_sha}
            _ -> {nil, nil}
          end

        _ ->
          {nil, nil}
      end
    end

    defp to_git_path("/" <> rest), do: rest
    defp to_git_path(path), do: path

    defp to_git_mode(mode) when is_integer(mode) do
      if Bitwise.band(mode, 0o111) != 0, do: "100755", else: "100644"
    end

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

    defp dir_stat do
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

    defp do_mkdir_recursive(s, path) do
      if exists?(s, path) do
        {:ok, s}
      else
        parent = Path.dirname(path)

        case do_mkdir_recursive(s, parent) do
          {:ok, s} -> write_file(s, path <> "/.gitkeep", "", [])
          err -> err
        end
      end
    end
  end
end
