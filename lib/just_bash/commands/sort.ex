defmodule JustBash.Commands.Sort do
  @moduledoc "The `sort` command - sort lines of text files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs.InMemoryFs

  @flag_spec %{
    boolean: [:r, :u, :n],
    value: [:k, :t],
    defaults: %{r: false, u: false, n: false, k: nil, t: nil}
  }

  @impl true
  def names, do: ["sort"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = FlagParser.parse(args, @flag_spec)
    content = get_content(bash, files, stdin)
    lines = String.split(content, "\n", trim: true)

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
      fn line -> get_sort_key(line, field_num, delimiter, flags.n) end,
      sort_direction(flags.r)
    )
  end

  defp sort_lines(lines, %{n: true} = flags) do
    Enum.sort_by(lines, &parse_leading_number/1, sort_direction(flags.r))
  end

  defp sort_lines(lines, %{r: true}), do: Enum.sort(lines, :desc)
  defp sort_lines(lines, _flags), do: Enum.sort(lines)

  defp parse_key_spec(spec) when is_integer(spec), do: {spec, nil}

  defp parse_key_spec(spec) when is_binary(spec) do
    # Parse key spec like "2" or "2,2" or "2.3"
    case Integer.parse(spec) do
      {n, _} -> {n, nil}
      :error -> {1, nil}
    end
  end

  defp get_sort_key(line, field_num, delimiter, numeric) do
    fields =
      if delimiter == " " do
        String.split(line, ~r/\s+/, trim: true)
      else
        String.split(line, delimiter)
      end

    field = Enum.at(fields, field_num - 1, "")

    if numeric do
      parse_leading_number(field)
    else
      field
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
