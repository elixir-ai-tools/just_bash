defmodule JustBash.Interpreter.Expansion.Glob do
  @moduledoc """
  Glob expansion and pattern matching utilities.

  Handles:
  - Filename expansion: *, ?, [...]
  - IFS word splitting
  - Converting glob patterns to regex
  """

  alias JustBash.FS
  alias JustBash.Limit

  # The filesystem plus the deadline the walk below is answerable to. Bundled
  # rather than passed separately so every step of the descent carries the
  # bound without widening five signatures.
  @typep walk :: {FS.t(), Limit.Deadline.t() | nil}

  @doc """
  Check if a string contains glob metacharacters.
  """
  @spec has_glob_chars?(String.t()) :: boolean()
  def has_glob_chars?(str) do
    String.contains?(str, "*") or String.contains?(str, "?") or
      Regex.match?(~r/\[[^\]]+\]/, str)
  end

  @doc """
  Expand a glob pattern against the filesystem.
  Returns a list of matching filenames, or the original pattern if no matches.

  Handles wildcards in any path segment, not just the filename.
  For example: /tmp/*/file.txt or /a/*/b/*.log

  Trailing slashes are preserved: /tmp/*/ expands to /tmp/foo/, /tmp/bar/
  """
  @spec expand(JustBash.t(), String.t()) :: [String.t()]
  def expand(bash, pattern) do
    has_trailing_slash = String.ends_with?(pattern, "/")
    {is_absolute, segments} = split_pattern_segments(pattern)
    base_dir = if is_absolute, do: "/", else: bash.cwd
    prefix = if is_absolute, do: "/", else: ""

    walk = {bash.fs, bash.interpreter.deadline}
    matches = expand_segments(walk, base_dir, prefix, segments, has_trailing_slash)

    if matches == [], do: [pattern], else: Enum.sort(matches)
  end

  # Split pattern into segments, handling absolute vs relative paths
  defp split_pattern_segments(pattern) do
    is_absolute = String.starts_with?(pattern, "/")
    stripped = if is_absolute, do: String.slice(pattern, 1..-1//1), else: pattern

    segments =
      stripped
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    {is_absolute, segments}
  end

  # Recursively expand segments, handling wildcards at any level
  # has_trailing_slash indicates if original pattern ended with /
  @spec expand_segments(walk(), String.t(), String.t(), [String.t()], boolean()) :: [String.t()]
  defp expand_segments(_walk, _current_path, prefix, [], has_trailing_slash) do
    # No more segments - return current path if it's not just the prefix
    if prefix == "" or prefix == "/" do
      []
    else
      result = String.trim_trailing(prefix, "/")
      # Append trailing slash if original pattern had one
      if has_trailing_slash, do: [result <> "/"], else: [result]
    end
  end

  defp expand_segments({fs, _deadline} = walk, current_path, prefix, [segment | rest], slash?) do
    if has_glob_chars?(segment) do
      # This segment has wildcards - expand it
      expand_wildcard_segment(walk, current_path, prefix, segment, rest, slash?)
    else
      # No wildcards - just append and continue
      next_path = join_path(current_path, segment)
      next_prefix = join_prefix(prefix, segment)

      case FS.stat(fs, next_path) do
        {:ok, _, _} ->
          expand_segments(walk, next_path, next_prefix, rest, slash?)

        {:error, _} ->
          # Path doesn't exist
          []
      end
    end
  end

  defp expand_wildcard_segment({fs, deadline} = walk, current_path, prefix, segment, rest, slash?) do
    regex_pattern = glob_pattern_to_regex(segment)

    with {:ok, regex} <- Regex.compile("^" <> regex_pattern <> "$"),
         {:ok, entries, _fs} <- FS.readdir(fs, current_path) do
      # A directory read is the unit of work this descent multiplies, so the
      # deadline is checked per matched entry — the same treatment `find` and
      # `grep -r` get. A whole glob is one step, so nothing else bounds it.
      entries
      |> Enum.filter(&matches_pattern?(&1, regex, segment))
      |> Limit.enforce_deadline(deadline)
      |> Enum.flat_map(fn entry ->
        expand_matched_entry(walk, current_path, prefix, entry, rest, slash?)
      end)
    else
      _ -> []
    end
  end

  defp expand_matched_entry({fs, _deadline} = walk, current_path, prefix, entry, rest, slash?) do
    next_path = join_path(current_path, entry)
    next_prefix = join_prefix(prefix, entry)

    if rest == [] do
      finalize_match(fs, next_path, next_prefix, slash?)
    else
      continue_expansion(walk, next_path, next_prefix, rest, slash?)
    end
  end

  defp finalize_match(fs, path, prefix, has_trailing_slash) do
    case FS.stat(fs, path) do
      {:ok, %VFS.Stat{type: type}, _fs} ->
        if has_trailing_slash and type == :directory,
          do: [prefix <> "/"],
          else: [prefix]

      {:error, _} ->
        []
    end
  end

  defp continue_expansion({fs, _deadline} = walk, path, prefix, rest, has_trailing_slash) do
    case FS.stat(fs, path) do
      {:ok, %VFS.Stat{type: :directory}, _fs} ->
        expand_segments(walk, path, prefix, rest, has_trailing_slash)

      _ ->
        []
    end
  end

  defp matches_pattern?(entry, regex, segment) do
    # Dotfiles only match if pattern explicitly starts with .
    if String.starts_with?(entry, ".") and not String.starts_with?(segment, ".") do
      false
    else
      Regex.match?(regex, entry)
    end
  end

  defp join_path("/", entry), do: "/" <> entry
  defp join_path(path, entry), do: path <> "/" <> entry

  defp join_prefix("", entry), do: entry
  defp join_prefix("/", entry), do: "/" <> entry
  defp join_prefix(prefix, entry), do: prefix <> "/" <> entry

  @doc """
  Split a string on IFS characters.
  """
  @spec split_on_ifs(String.t(), String.t()) :: [String.t()]
  def split_on_ifs(str, ifs) when ifs == "", do: [str]

  def split_on_ifs(str, ifs) do
    ifs_chars = String.graphemes(ifs)
    regex_pattern = "[" <> Regex.escape(Enum.join(ifs_chars)) <> "]+"

    case Regex.compile(regex_pattern) do
      {:ok, regex} ->
        String.split(str, regex, trim: true)

      {:error, _} ->
        String.split(str, ~r/\s+/, trim: true)
    end
  end

  @doc """
  Convert a glob pattern to a regex pattern string.
  """
  @spec glob_pattern_to_regex(String.t()) :: String.t()
  def glob_pattern_to_regex(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join(fn
      "*" -> ".*"
      "?" -> "."
      "[" -> "["
      "]" -> "]"
      c -> Regex.escape(c)
    end)
  end
end
