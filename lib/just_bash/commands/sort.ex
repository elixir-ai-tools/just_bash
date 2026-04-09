defmodule JustBash.Commands.Sort do
  @moduledoc "The `sort` command - sort lines of text files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs

  @flag_spec %{
    boolean: [:r, :u, :n, :f],
    value: [:t],
    multi_value: [:k],
    defaults: %{r: false, u: false, n: false, f: false, k: [], t: nil}
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
    resolved = Fs.resolve_path(bash.cwd, file)

    case Fs.read_file(bash.fs, resolved) do
      {:ok, c} -> c
      {:error, _} -> ""
    end
  end

  defp sort_lines(lines, %{k: key_specs} = flags) when key_specs != [] do
    delimiter = flags[:t] || " "

    parsed_keys =
      Enum.map(key_specs, fn spec ->
        {field_num, modifiers} = parse_key_spec(spec)
        numeric = modifiers[:numeric] || flags.n
        fold_case = modifiers[:fold_case] || flags.f
        reverse = modifiers[:reverse] || flags.r
        {field_num, numeric, fold_case, reverse}
      end)

    Enum.sort(lines, fn a, b ->
      compare_by_keys(a, b, parsed_keys, delimiter)
    end)
  end

  defp sort_lines(lines, %{n: true} = flags) do
    Enum.sort_by(lines, &parse_leading_number/1, sort_direction(flags.r))
  end

  defp sort_lines(lines, %{f: true} = flags) do
    # Case-insensitive sort: sort by downcased key, use stable sort
    Enum.sort_by(lines, &String.downcase/1, sort_direction(flags.r))
  end

  defp sort_lines(lines, %{r: true}), do: Enum.sort(lines, &>=/2)
  defp sort_lines(lines, _flags), do: Enum.sort(lines, &<=/2)

  defp compare_by_keys(_a, _b, [], _delimiter), do: true

  defp compare_by_keys(a, b, [{field_num, numeric, fold_case, reverse} | rest], delimiter) do
    key_a = get_sort_key(a, field_num, delimiter, numeric, fold_case)
    key_b = get_sort_key(b, field_num, delimiter, numeric, fold_case)

    cond do
      key_a == key_b ->
        compare_by_keys(a, b, rest, delimiter)

      reverse ->
        key_a > key_b

      true ->
        key_a < key_b
    end
  end

  defp parse_key_spec(spec) when is_integer(spec), do: {spec, nil}

  defp parse_key_spec(spec) when is_binary(spec) do
    # Parse key spec like "2" or "2,2" or "2,2nr" or "1,1rn"
    # Extract field number and modifiers (n=numeric, r=reverse, f=fold-case)
    case Integer.parse(spec) do
      {n, rest} ->
        modifiers = parse_key_modifiers(rest)
        {n, modifiers}

      :error ->
        {1, %{}}
    end
  end

  defp parse_key_modifiers(rest) do
    # After the field number, there may be ",end" and then modifier chars
    # e.g. ",2nr" or ",1rn" or "nr" or just ""
    chars =
      case String.split(rest, ",", parts: 2) do
        [_] -> rest
        [_, end_spec] -> end_spec
      end

    # Strip any leading digits (the end field number) to get modifier letters
    modifier_str = String.replace(chars, ~r/^[\d.]*/, "")

    %{
      numeric: String.contains?(modifier_str, "n"),
      reverse: String.contains?(modifier_str, "r"),
      fold_case: String.contains?(modifier_str, "f")
    }
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
