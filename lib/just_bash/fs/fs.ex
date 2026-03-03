defmodule JustBash.Fs do
  @moduledoc """
  Filesystem behaviour and utility functions for JustBash.

  This module defines the common interface for filesystem implementations
  and provides utility functions for path manipulation.
  """

  alias JustBash.Fs.InMemoryFs

  @type stat_result :: %{
          is_file: boolean(),
          is_directory: boolean(),
          is_symbolic_link: boolean(),
          mode: non_neg_integer(),
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type mkdir_opts :: [recursive: boolean()]
  @type rm_opts :: [recursive: boolean(), force: boolean()]
  @type cp_opts :: [recursive: boolean()]

  @doc """
  Create a new in-memory filesystem with optional initial files.
  """
  defdelegate new(initial_files \\ %{}), to: InMemoryFs

  @doc """
  Normalize a filesystem path.
  """
  defdelegate normalize_path(path), to: InMemoryFs

  @doc """
  Get the directory name (parent path) of a path.
  """
  defdelegate dirname(path), to: InMemoryFs

  @doc """
  Get the base name (file name) of a path.
  """
  defdelegate basename(path), to: InMemoryFs

  @doc """
  Resolve a path relative to a base path.
  """
  defdelegate resolve_path(base, path), to: InMemoryFs

  @doc """
  Check if a path exists in the filesystem.
  """
  defdelegate exists?(fs, path), to: InMemoryFs

  @doc """
  Get stat information for a path (follows symlinks).
  """
  defdelegate stat(fs, path), to: InMemoryFs

  @doc """
  Get stat information for a path (does NOT follow symlinks).
  """
  defdelegate lstat(fs, path), to: InMemoryFs

  @doc """
  Read the contents of a file.
  """
  defdelegate read_file(fs, path), to: InMemoryFs

  @doc """
  Write content to a file.
  """
  defdelegate write_file(fs, path, content), to: InMemoryFs
  defdelegate write_file(fs, path, content, opts), to: InMemoryFs

  @doc """
  Append content to a file.
  """
  defdelegate append_file(fs, path, content), to: InMemoryFs

  @doc """
  Create a directory.
  """
  defdelegate mkdir(fs, path), to: InMemoryFs
  defdelegate mkdir(fs, path, opts), to: InMemoryFs

  @doc """
  Read directory contents.
  """
  defdelegate readdir(fs, path), to: InMemoryFs

  @doc """
  Remove a file or directory.
  """
  defdelegate rm(fs, path), to: InMemoryFs
  defdelegate rm(fs, path, opts), to: InMemoryFs

  @doc """
  Copy a file or directory.
  """
  defdelegate cp(fs, src, dest), to: InMemoryFs
  defdelegate cp(fs, src, dest, opts), to: InMemoryFs

  @doc """
  Move/rename a file or directory.
  """
  defdelegate mv(fs, src, dest), to: InMemoryFs

  @doc """
  Change file/directory permissions.
  """
  defdelegate chmod(fs, path, mode), to: InMemoryFs

  @doc """
  Create a symbolic link.
  """
  defdelegate symlink(fs, target, link_path), to: InMemoryFs

  @doc """
  Read the target of a symbolic link.
  """
  defdelegate readlink(fs, path), to: InMemoryFs

  @doc """
  Create a hard link.
  """
  defdelegate link(fs, existing_path, new_path), to: InMemoryFs

  @doc """
  Get all paths in the filesystem.
  """
  defdelegate get_all_paths(fs), to: InMemoryFs

  @doc """
  Materialize a single file's lazy content to binary.
  """
  defdelegate materialize(fs, path), to: InMemoryFs

  @doc """
  Materialize all lazy file content to binary.
  """
  defdelegate materialize_all(fs), to: InMemoryFs
end
