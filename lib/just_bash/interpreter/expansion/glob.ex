defmodule JustBash.Interpreter.Expansion.Glob do
  @moduledoc """
  Glob expansion and pattern matching utilities.

  Handles:
  - Filename expansion: *, ?, [...]
  - IFS word splitting
  - Converting glob patterns to regex
  """

  alias JustBash.Fs.InMemoryFs

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
  """
  @spec expand(JustBash.t(), String.t()) :: [String.t()]
  def expand(bash, pattern) do
    dir = if String.starts_with?(pattern, "/"), do: "/", else: bash.cwd
    {dir_pattern, file_pattern} = split_glob_pattern(bash.cwd, dir, pattern)
    regex_pattern = glob_pattern_to_regex(file_pattern)

    with {:ok, regex} <- Regex.compile("^" <> regex_pattern <> "$"),
         {:ok, entries} <- InMemoryFs.readdir(bash.fs, dir_pattern) do
      matches = filter_and_format_matches(entries, regex, dir_pattern, bash.cwd)
      if matches == [], do: [pattern], else: matches
    else
      _ -> [pattern]
    end
  end

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

  # Private helpers

  defp split_glob_pattern(cwd, dir, pattern) do
    case String.split(pattern, "/") |> Enum.reverse() do
      [file] ->
        {dir, file}

      [file | rest] ->
        dir_part = rest |> Enum.reverse() |> Enum.join("/")
        resolved_dir = resolve_glob_dir(cwd, dir_part)
        {resolved_dir, file}
    end
  end

  defp resolve_glob_dir(cwd, dir_part) do
    if String.starts_with?(dir_part, "/"),
      do: dir_part,
      else: InMemoryFs.resolve_path(cwd, dir_part)
  end

  defp filter_and_format_matches(entries, regex, dir_pattern, cwd) do
    entries
    |> Enum.filter(fn entry ->
      Regex.match?(regex, entry) and not String.starts_with?(entry, ".")
    end)
    |> Enum.sort()
    |> Enum.map(fn entry ->
      if dir_pattern == cwd, do: entry, else: Path.join(dir_pattern, entry)
    end)
  end
end
