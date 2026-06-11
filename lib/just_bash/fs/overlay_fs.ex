defmodule JustBash.Fs.OverlayFS do
  @moduledoc """
  A union filesystem backend that layers a writable upper backend over a
  read-only lower backend, similar to overlayfs on Linux.

  Reads check the upper layer first; on miss they fall through to the lower
  layer. Writes always go to the upper layer. Deletions are tracked as
  whiteouts so that removed lower-layer entries stay hidden.

  ## Usage

      git = GitFS.new("https://github.com/org/repo")
      overlay = OverlayFS.new(lower: {GitFS, git})
      {:ok, fs} = Fs.mount(fs, "/repo", OverlayFS, overlay)

  The upper layer defaults to a fresh `InMemoryFs`. You can supply your own:

      overlay = OverlayFS.new(
        lower: {GitFS, git},
        upper: {InMemoryFs, InMemoryFs.new(%{"/seed.txt" => "pre-loaded"})}
      )
  """

  @behaviour JustBash.Fs.Backend

  alias JustBash.Fs.InMemoryFs

  @type t :: %__MODULE__{
          lower_mod: module(),
          lower_state: term(),
          upper_state: term(),
          whiteouts: MapSet.t(String.t())
        }

  defstruct [:lower_mod, :lower_state, :upper_state, whiteouts: MapSet.new()]

  @spec new(keyword()) :: t()
  def new(opts) do
    {lower_mod, lower_state} = Keyword.fetch!(opts, :lower)

    upper_state =
      case Keyword.get(opts, :upper) do
        {_mod, state} -> state
        nil -> InMemoryFs.new()
      end

    %__MODULE__{
      lower_mod: lower_mod,
      lower_state: lower_state,
      upper_state: upper_state,
      whiteouts: MapSet.new()
    }
  end

  # --- Read ops ---

  @impl true
  def exists?(%__MODULE__{} = s, path) do
    not whiteout?(s, path) and
      (InMemoryFs.exists?(s.upper_state, path) or
         s.lower_mod.exists?(s.lower_state, path))
  end

  @impl true
  def stat(%__MODULE__{} = s, path) do
    if whiteout?(s, path), do: {:error, :enoent}, else: upper_then_lower(s, path, :stat)
  end

  @impl true
  def lstat(%__MODULE__{} = s, path) do
    if whiteout?(s, path), do: {:error, :enoent}, else: upper_then_lower(s, path, :lstat)
  end

  @impl true
  def read_file(%__MODULE__{} = s, path) do
    if whiteout?(s, path), do: {:error, :enoent}, else: upper_then_lower(s, path, :read_file)
  end

  @impl true
  def readdir(%__MODULE__{} = s, path) do
    if whiteout?(s, path) do
      {:error, :enoent}
    else
      upper_entries = safe_readdir(InMemoryFs, s.upper_state, path)
      lower_entries = safe_readdir(s.lower_mod, s.lower_state, path)

      case {upper_entries, lower_entries} do
        {[], []} ->
          if InMemoryFs.exists?(s.upper_state, path) or
               s.lower_mod.exists?(s.lower_state, path) do
            {:ok, []}
          else
            {:error, :enoent}
          end

        _ ->
          merged =
            (upper_entries ++ lower_entries)
            |> Enum.uniq()
            |> Enum.reject(fn name ->
              child = join_path(path, name)
              whiteout?(s, child)
            end)
            |> Enum.sort()

          {:ok, merged}
      end
    end
  end

  @impl true
  def readlink(%__MODULE__{} = s, path) do
    if whiteout?(s, path), do: {:error, :enoent}, else: upper_then_lower(s, path, :readlink)
  end

  # --- Write ops (all go to upper) ---

  @impl true
  def write_file(%__MODULE__{} = s, path, content, opts) do
    case InMemoryFs.write_file(s.upper_state, path, content, opts) do
      {:ok, new_upper} ->
        {:ok, %{s | upper_state: new_upper, whiteouts: remove_whiteout(s.whiteouts, path)}}

      error ->
        error
    end
  end

  @impl true
  def append_file(%__MODULE__{} = s, path, content) do
    if whiteout?(s, path) do
      {:error, :enoent}
    else
      case InMemoryFs.read_file(s.upper_state, path) do
        {:ok, _existing} ->
          case InMemoryFs.append_file(s.upper_state, path, content) do
            {:ok, new_upper} -> {:ok, %{s | upper_state: new_upper}}
            error -> error
          end

        {:error, :enoent} ->
          case s.lower_mod.read_file(s.lower_state, path) do
            {:ok, existing} ->
              cow_and_append(s, path, existing, content)

            {:error, _} = err ->
              err
          end
      end
    end
  end

  @impl true
  def mkdir(%__MODULE__{} = s, path, opts) do
    case InMemoryFs.mkdir(s.upper_state, path, opts) do
      {:ok, new_upper} ->
        {:ok, %{s | upper_state: new_upper, whiteouts: remove_whiteout(s.whiteouts, path)}}

      error ->
        error
    end
  end

  @impl true
  def rm(%__MODULE__{} = s, path, opts) do
    in_upper = InMemoryFs.exists?(s.upper_state, path)
    in_lower = not whiteout?(s, path) and s.lower_mod.exists?(s.lower_state, path)

    if not in_upper and not in_lower do
      if Keyword.get(opts, :force), do: {:ok, s}, else: {:error, :enoent}
    else
      s = if in_lower, do: add_whiteout(s, path), else: s

      if in_upper do
        case InMemoryFs.rm(s.upper_state, path, opts) do
          {:ok, new_upper} -> {:ok, %{s | upper_state: new_upper}}
          error -> error
        end
      else
        {:ok, s}
      end
    end
  end

  @impl true
  def chmod(%__MODULE__{} = s, path, mode) do
    if whiteout?(s, path) do
      {:error, :enoent}
    else
      case InMemoryFs.chmod(s.upper_state, path, mode) do
        {:ok, new_upper} ->
          {:ok, %{s | upper_state: new_upper}}

        {:error, :enoent} ->
          case s.lower_mod.read_file(s.lower_state, path) do
            {:ok, content} ->
              {:ok, upper} = InMemoryFs.write_file(s.upper_state, path, content, mode: mode)
              {:ok, %{s | upper_state: upper}}

            {:error, _} = err ->
              err
          end
      end
    end
  end

  @impl true
  def symlink(%__MODULE__{} = s, target, link_path) do
    case InMemoryFs.symlink(s.upper_state, target, link_path) do
      {:ok, new_upper} ->
        {:ok, %{s | upper_state: new_upper, whiteouts: remove_whiteout(s.whiteouts, link_path)}}

      error ->
        error
    end
  end

  @impl true
  def link(%__MODULE__{} = s, existing, new_path) do
    if whiteout?(s, existing) do
      {:error, :enoent}
    else
      case InMemoryFs.read_file(s.upper_state, existing) do
        {:ok, _} ->
          case InMemoryFs.link(s.upper_state, existing, new_path) do
            {:ok, new_upper} -> {:ok, %{s | upper_state: new_upper}}
            error -> error
          end

        {:error, :enoent} ->
          case s.lower_mod.read_file(s.lower_state, existing) do
            {:ok, content} ->
              {:ok, upper} = InMemoryFs.write_file(s.upper_state, existing, content, [])
              cow_link(s, upper, existing, new_path)

            {:error, _} = err ->
              err
          end
      end
    end
  end

  # --- Helpers ---

  defp upper_then_lower(s, path, op) do
    case apply(InMemoryFs, op, [s.upper_state, path]) do
      {:ok, _} = result -> result
      {:error, :enoent} -> apply(s.lower_mod, op, [s.lower_state, path])
      error -> error
    end
  end

  defp safe_readdir(mod, state, path) do
    case mod.readdir(state, path) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  defp whiteout?(%__MODULE__{whiteouts: wo}, path) do
    MapSet.member?(wo, path) or ancestor_whiteout?(wo, path)
  end

  defp ancestor_whiteout?(wo, path) do
    path
    |> ancestors()
    |> Enum.any?(&MapSet.member?(wo, &1))
  end

  defp ancestors(path) do
    parts = path |> String.trim_leading("/") |> String.split("/")

    parts
    |> Enum.scan("", fn part, acc -> acc <> "/" <> part end)
    |> Enum.drop(-1)
  end

  defp add_whiteout(s, path), do: %{s | whiteouts: MapSet.put(s.whiteouts, path)}

  defp remove_whiteout(wo, path), do: MapSet.delete(wo, path)

  defp join_path("/", name), do: "/" <> name
  defp join_path(dir, name), do: dir <> "/" <> name

  defp cow_and_append(s, path, existing, content) do
    {:ok, upper} = InMemoryFs.write_file(s.upper_state, path, existing <> content, [])
    {:ok, %{s | upper_state: upper}}
  end

  defp cow_link(s, upper, existing, new_path) do
    case InMemoryFs.link(upper, existing, new_path) do
      {:ok, new_upper} -> {:ok, %{s | upper_state: new_upper}}
      error -> error
    end
  end
end
