defmodule JustBash.FS.Backend do
  @moduledoc """
  Behaviour for pluggable filesystem backends.

  Backends operate on their own root-relative paths and have no knowledge of the
  mount table. All cross-backend concerns (cross-mount `cp`, synthetic mountpoint
  entries, longest-prefix routing) live in `JustBash.FS`.

  ## Path contract

  A backend receives **backend-relative absolute paths** — always starting with `/`,
  already normalized, with the mountpoint prefix stripped. The backend behaves as if
  it were the entire filesystem rooted at `/`.

  ## Return conventions

  - Mutating ops return `{:ok, new_state} | {:error, reason}`.
  - Query ops return `{:ok, value} | {:error, reason}` except `exists?/2`, which
    returns a `boolean()`.
  - `reason` is a POSIX-style atom: `:enoent`, `:eisdir`, `:enotdir`, `:eloop`,
    `:einval`, `:eexist`, `:eacces`, `:erofs`, `:exdev`, etc.
  """

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

  @type write_opts :: [mode: non_neg_integer(), mtime: DateTime.t()]
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
