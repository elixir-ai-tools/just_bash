defmodule JustBash.Interpreter.Expansion.Glob do
  @moduledoc """
  Glob expansion and pattern matching utilities.

  Handles:
  - Filename expansion: *, ?, [...]
  - IFS word splitting
  - Converting glob patterns to regex
  """

  alias JustBash.Fs.InMemoryFs
  alias JustBash.Limits

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

    {matches, _match_count, _walk_count} =
      expand_segments(bash, bash.fs, base_dir, prefix, segments, has_trailing_slash, 0, 0)

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
  defp expand_segments(
         bash,
         _fs,
         _current_path,
         prefix,
         [],
         has_trailing_slash,
         match_count,
         walk_count
       ) do
    # No more segments - return current path if it's not just the prefix
    if prefix == "" or prefix == "/" do
      {[], match_count, walk_count}
    else
      result = String.trim_trailing(prefix, "/")
      new_match_count = match_count + 1
      Limits.check_glob_matches!(bash, new_match_count)
      # Append trailing slash if original pattern had one
      final = if has_trailing_slash, do: [result <> "/"], else: [result]
      {final, new_match_count, walk_count}
    end
  end

  defp expand_segments(
         bash,
         fs,
         current_path,
         prefix,
         [segment | rest],
         has_trailing_slash,
         match_count,
         walk_count
       ) do
    if has_glob_chars?(segment) do
      # This segment has wildcards - expand it
      expand_wildcard_segment(
        bash,
        fs,
        current_path,
        prefix,
        segment,
        rest,
        has_trailing_slash,
        match_count,
        walk_count
      )
    else
      # No wildcards - just append and continue
      next_path = join_path(current_path, segment)
      next_prefix = join_prefix(prefix, segment)

      case InMemoryFs.stat(fs, next_path) do
        {:ok, _} ->
          expand_segments(
            bash,
            fs,
            next_path,
            next_prefix,
            rest,
            has_trailing_slash,
            match_count,
            walk_count
          )

        {:error, _} ->
          # Path doesn't exist
          {[], match_count, walk_count}
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp expand_wildcard_segment(
         bash,
         fs,
         current_path,
         prefix,
         segment,
         rest,
         has_trailing_slash,
         match_count,
         walk_count
       ) do
    regex_pattern = glob_pattern_to_regex(segment)

    with {:ok, regex} <- Regex.compile("^" <> regex_pattern <> "$"),
         {:ok, entries} <- InMemoryFs.readdir(fs, current_path) do
      new_walk_count = walk_count + length(entries)
      Limits.check_file_walk!(bash, new_walk_count)

      entries
      |> Enum.reduce({[], match_count, new_walk_count}, fn entry, {acc, acc_matches, acc_walk} ->
        if matches_pattern?(entry, regex, segment) do
          {entry_matches, next_match_count, next_walk_count} =
            expand_matched_entry(
              bash,
              fs,
              current_path,
              prefix,
              entry,
              rest,
              has_trailing_slash,
              acc_matches,
              acc_walk
            )

          {[entry_matches | acc], next_match_count, next_walk_count}
        else
          {acc, acc_matches, acc_walk}
        end
      end)
      |> then(fn {acc, final_match_count, final_walk_count} ->
        {acc |> Enum.reverse() |> List.flatten(), final_match_count, final_walk_count}
      end)
    else
      _ -> {[], match_count, walk_count}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp expand_matched_entry(
         bash,
         fs,
         current_path,
         prefix,
         entry,
         rest,
         has_trailing_slash,
         match_count,
         walk_count
       ) do
    next_path = join_path(current_path, entry)
    next_prefix = join_prefix(prefix, entry)

    if rest == [] do
      finalize_match(
        bash,
        fs,
        next_path,
        next_prefix,
        has_trailing_slash,
        match_count,
        walk_count
      )
    else
      continue_expansion(
        bash,
        fs,
        next_path,
        next_prefix,
        rest,
        has_trailing_slash,
        match_count,
        walk_count
      )
    end
  end

  defp finalize_match(bash, fs, path, prefix, has_trailing_slash, match_count, walk_count) do
    case InMemoryFs.stat(fs, path) do
      {:ok, stat} ->
        new_match_count = match_count + 1
        Limits.check_glob_matches!(bash, new_match_count)

        if has_trailing_slash and stat.is_directory,
          do: {[prefix <> "/"], new_match_count, walk_count},
          else: {[prefix], new_match_count, walk_count}

      {:error, _} ->
        {[], match_count, walk_count}
    end
  end

  defp continue_expansion(
         bash,
         fs,
         path,
         prefix,
         rest,
         has_trailing_slash,
         match_count,
         walk_count
       ) do
    case InMemoryFs.stat(fs, path) do
      {:ok, %{is_directory: true}} ->
        expand_segments(bash, fs, path, prefix, rest, has_trailing_slash, match_count, walk_count)

      _ ->
        {[], match_count, walk_count}
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
