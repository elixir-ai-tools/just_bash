defprotocol JustBash.FS.POSIX do
  @moduledoc """
  POSIX filesystem extensions that are not part of `VFS.Mountable`.

  The vfs protocol deliberately keeps its surface to ten universal
  operations; symlinks, hard links, permission bits, and append are
  POSIX-specific concepts that most virtual backends (git trees, S3
  objects, DB rows) cannot express. This secondary protocol carries
  them for the backends that can — today `JustBash.FS.Memory` — while
  every other `VFS.Mountable` gets graceful degradation through the
  `Any` fallback:

  - `lstat/2` falls back to `VFS.stat/2` (no symlinks means stat and
    lstat agree)
  - `readlink/2` returns `:einval` (nothing is ever a symlink)
  - `symlink/3` and `link/3` return `:enotsup`
  - `chmod/3` is a validated no-op (succeeds if the path exists)
  - `append_file/3` composes read + write

  A `%VFS{}` mount table implements this protocol by routing to the
  backend that owns the path, exactly as it routes the core operations.

  All returns follow the vfs conventions: state threads back on success,
  errors are `%VFS.Error{}` structs.
  """

  @fallback_to_any true

  @type path :: String.t()

  @spec lstat(t, path) :: {:ok, VFS.Stat.t(), t} | {:error, VFS.Error.t()}
  def lstat(fs, path)

  @spec readlink(t, path) :: {:ok, String.t(), t} | {:error, VFS.Error.t()}
  def readlink(fs, path)

  @spec symlink(t, String.t(), path) :: {:ok, t} | {:error, VFS.Error.t()}
  def symlink(fs, target, link_path)

  @spec link(t, path, path) :: {:ok, t} | {:error, VFS.Error.t()}
  def link(fs, existing_path, new_path)

  @spec chmod(t, path, non_neg_integer()) :: {:ok, t} | {:error, VFS.Error.t()}
  def chmod(fs, path, mode)

  @spec append_file(t, path, binary()) :: {:ok, t} | {:error, VFS.Error.t()}
  def append_file(fs, path, content)
end

defimpl JustBash.FS.POSIX, for: JustBash.FS.Memory do
  alias JustBash.FS.Memory

  def lstat(%Memory{} = fs, path), do: Memory.lstat(fs, path)
  def readlink(%Memory{} = fs, path), do: Memory.readlink(fs, path)
  def symlink(%Memory{} = fs, target, link_path), do: Memory.symlink(fs, target, link_path)
  def link(%Memory{} = fs, existing, new), do: Memory.link(fs, existing, new)
  def chmod(%Memory{} = fs, path, mode), do: Memory.chmod(fs, path, mode)
  def append_file(%Memory{} = fs, path, content), do: Memory.append_file(fs, path, content)
end

defimpl JustBash.FS.POSIX, for: VFS do
  @moduledoc false

  # Mount-table routing for the POSIX extensions, mirroring how the
  # `VFS.Mountable` defimpl for `VFS` routes the core operations:
  # normalize, resolve to the owning mount, dispatch in the backend's
  # namespace, thread the updated backend back into the table, and
  # rewrite error paths into the caller's namespace.

  alias JustBash.FS.POSIX
  alias VFS.Error

  def lstat(%VFS{} = vfs, path), do: route_read(vfs, path, &POSIX.lstat(&1, &2))
  def readlink(%VFS{} = vfs, path), do: route_read(vfs, path, &POSIX.readlink(&1, &2))

  def symlink(%VFS{} = vfs, target, link_path) do
    route_mutation(vfs, link_path, &POSIX.symlink(&1, target, &2))
  end

  # Both paths must resolve, and to the same mount; each failure names
  # the path that caused it. `:exdev` and the new-path errors carry the
  # new path, matching how ln reports "failed to create hard link NEW".
  def link(%VFS{} = vfs, existing_path, new_path) do
    p_existing = VFS.Path.normalize(existing_path)
    p_new = VFS.Path.normalize(new_path)

    case {resolve(vfs, p_existing), resolve(vfs, p_new)} do
      {{:ok, mp, sub_existing, _}, {:ok, mp, sub_new, backend}} ->
        case POSIX.link(backend, sub_existing, sub_new) do
          {:ok, new_backend} ->
            {:ok, VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, %Error{} = err} ->
            {:error, err |> Error.put_path(p_new) |> Error.put_mount(mp)}
        end

      {{:ok, _, _, _}, {:ok, _, _, _}} ->
        {:error, Error.new(:exdev, path: p_new)}

      {:no_mount, _} ->
        {:error, Error.new(:enoent, path: p_existing)}

      {_, :no_mount} ->
        {:error, Error.new(:enoent, path: p_new)}
    end
  end

  def chmod(%VFS{} = vfs, path, mode), do: route_mutation(vfs, path, &POSIX.chmod(&1, &2, mode))

  def append_file(%VFS{} = vfs, path, content) do
    route_mutation(vfs, path, &POSIX.append_file(&1, &2, content))
  end

  defp route_read(%VFS{} = vfs, path, fun) do
    p = VFS.Path.normalize(path)

    case resolve(vfs, p) do
      {:ok, mp, sub, backend} ->
        case fun.(backend, sub) do
          {:ok, payload, new_backend} ->
            {:ok, payload, VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, %Error{} = err} ->
            {:error, err |> Error.put_path(p) |> Error.put_mount(mp)}
        end

      :no_mount ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  defp route_mutation(%VFS{} = vfs, path, fun) do
    p = VFS.Path.normalize(path)

    case resolve(vfs, p) do
      {:ok, mp, sub, backend} ->
        case fun.(backend, sub) do
          {:ok, new_backend} ->
            {:ok, VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, %Error{} = err} ->
            {:error, err |> Error.put_path(p) |> Error.put_mount(mp)}
        end

      :no_mount ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  defp resolve(vfs, path), do: VFS.__resolve__(vfs, path)
end

defimpl JustBash.FS.POSIX, for: Any do
  @moduledoc false

  # Graceful degradation for backends without POSIX extensions: a plain
  # `VFS.Memory` mount, an exgit repo, any future S3-shaped backend.

  alias VFS.Error

  def lstat(fs, path), do: VFS.stat(fs, path)

  def readlink(fs, path) do
    case VFS.exists?(fs, path) do
      {true, _fs} -> {:error, Error.new(:einval, path: path)}
      {false, _fs} -> {:error, Error.new(:enoent, path: path)}
    end
  end

  def symlink(_fs, _target, link_path), do: {:error, Error.new(:enotsup, path: link_path)}

  def link(_fs, existing_path, _new_path), do: {:error, Error.new(:enotsup, path: existing_path)}

  def chmod(fs, path, _mode) do
    case VFS.exists?(fs, path) do
      {true, fs} -> {:ok, fs}
      {false, _fs} -> {:error, Error.new(:enoent, path: path)}
    end
  end

  def append_file(fs, path, content) do
    case VFS.read_file(fs, path) do
      {:ok, existing, fs} -> VFS.write_file(fs, path, existing <> content)
      {:error, %Error{kind: :enoent}} -> VFS.write_file(fs, path, content)
      {:error, %Error{} = err} -> {:error, err}
    end
  end
end
