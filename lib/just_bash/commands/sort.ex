defmodule JustBash.Commands.Sort do
  @moduledoc "The `sort` command - sort lines of text files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs.InMemoryFs

  @flag_spec %{
    boolean: [:r, :u, :n, :f],
    value: [:k, :t],
    defaults: %{r: false, u: false, n: false, f: false, k: nil, t: nil}
  }

  @impl true
  def names, do: ["sort"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = FlagParser.parse(args, @flag_spec)
    content = get_content(bash, files, stdin)
    # Don't trim - preserve empty lines. Only remove trailing empty if content ends with \n
    lines = String.split(content, "\n", trim: false)

    lines =
      if List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    sorted =
      lines
      |> sort_lines(flags)
      |> maybe_uniq(flags.u)

    output = format_output(sorted)
    {Command.ok(output), bash}
  end

  defp get_content(_bash, [], stdin), do: stdin

  defp get_content(bash, [file | _], _stdin) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, c} -> c
      {:error, _} -> ""
    end
  end

  defp sort_lines(lines, %{k: key_spec} = flags) when key_spec != nil do
    {field_num, _} = parse_key_spec(key_spec)
    delimiter = flags[:t] || " "

    Enum.sort_by(
      lines,
      fn line -> get_sort_key(line, field_num, delimiter, flags.n, flags.f) end,
      sort_direction(flags.r)
    )
  end

  defp sort_lines(lines, %{n: true} = flags) do
    Enum.sort_by(lines, &parse_leading_number/1, sort_direction(flags.r))
  end

  defp sort_lines(lines, %{f: true} = flags) do
    # Case-insensitive sort: sort by downcased key, use stable sort
    Enum.sort_by(lines, &String.downcase/1, sort_direction(flags.r))
  end

  defp sort_lines(lines, %{r: true}), do: Enum.sort(lines, &locale_compare_desc/2)
  defp sort_lines(lines, _flags), do: Enum.sort(lines, &locale_compare_asc/2)

  # Locale-aware comparison (similar to en_US.UTF-8 collation)
  # Case-insensitive primary sort, lowercase before uppercase as tiebreaker
  defp locale_compare_asc(a, b) do
    a_down = String.downcase(a)
    b_down = String.downcase(b)

    cond do
      a_down < b_down -> true
      a_down > b_down -> false
      true -> is_lowercase_first?(a, b)
    end
  end

  defp locale_compare_desc(a, b), do: locale_compare_asc(b, a)

  defp is_lowercase_first?(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    compare_chars(a_chars, b_chars)
  end

  defp compare_chars([], []), do: true
  defp compare_chars([], _), do: true
  defp compare_chars(_, []), do: false

  defp compare_chars([a_char | a_rest], [b_char | b_rest]) do
    a_down = String.downcase(a_char)
    b_down = String.downcase(b_char)

    cond do
      a_down != b_down -> a_down <= b_down
      a_char == b_char -> compare_chars(a_rest, b_rest)
      is_lowercase?(a_char) and not is_lowercase?(b_char) -> true
      not is_lowercase?(a_char) and is_lowercase?(b_char) -> false
      true -> compare_chars(a_rest, b_rest)
    end
  end

  defp is_lowercase?(char) do
    String.downcase(char) == char and String.upcase(char) != char
  end

  defp parse_key_spec(spec) when is_integer(spec), do: {spec, nil}

  defp parse_key_spec(spec) when is_binary(spec) do
    # Parse key spec like "2" or "2,2" or "2.3"
    case Integer.parse(spec) do
      {n, _} -> {n, nil}
      :error -> {1, nil}
    end
  end

  defp get_sort_key(line, field_num, delimiter, numeric, fold_case) do
    fields =
      if delimiter == " " do
        String.split(line, ~r/\s+/, trim: true)
      else
        String.split(line, delimiter)
      end

    field = Enum.at(fields, field_num - 1, "")

    cond do
      numeric -> parse_leading_number(field)
      fold_case -> String.downcase(field)
      true -> field
    end
  end

  defp parse_leading_number(line) do
    case Integer.parse(String.trim(line)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp sort_direction(true), do: :desc
  defp sort_direction(false), do: :asc

  defp maybe_uniq(sorted, true), do: Enum.uniq(sorted)
  defp maybe_uniq(sorted, false), do: sorted

  defp format_output([]), do: ""
  defp format_output(sorted), do: Enum.join(sorted, "\n") <> "\n"
end
