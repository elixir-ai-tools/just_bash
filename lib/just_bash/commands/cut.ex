defmodule JustBash.Commands.Cut do
  @moduledoc "The `cut` command - remove sections from each line of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["cut"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        content = get_content(bash, opts.files, stdin)
        output = process_content(content, opts)
        {Command.ok(output), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      delimiter: "\t",
      field_spec: nil,
      char_spec: nil,
      suppress_no_delim: false,
      files: []
    })
  end

  defp parse_args([], opts) do
    if opts.field_spec == nil and opts.char_spec == nil do
      {:error, "cut: you must specify a list of bytes, characters, or fields\n"}
    else
      {:ok, opts}
    end
  end

  defp parse_args(["-d", delim | rest], opts) do
    parse_args(rest, %{opts | delimiter: delim})
  end

  defp parse_args(["-d" <> delim | rest], opts) when delim != "" do
    parse_args(rest, %{opts | delimiter: delim})
  end

  defp parse_args(["-f", spec | rest], opts) do
    parse_args(rest, %{opts | field_spec: spec})
  end

  defp parse_args(["-f" <> spec | rest], opts) when spec != "" do
    parse_args(rest, %{opts | field_spec: spec})
  end

  defp parse_args(["-c", spec | rest], opts) do
    parse_args(rest, %{opts | char_spec: spec})
  end

  defp parse_args(["-c" <> spec | rest], opts) when spec != "" do
    parse_args(rest, %{opts | char_spec: spec})
  end

  defp parse_args(["-s" | rest], opts) do
    parse_args(rest, %{opts | suppress_no_delim: true})
  end

  defp parse_args(["--only-delimited" | rest], opts) do
    parse_args(rest, %{opts | suppress_no_delim: true})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "cut: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp get_content(_bash, [], stdin), do: stdin

  defp get_content(bash, files, _stdin) do
    Enum.map_join(files, "", fn file ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case InMemoryFs.read_file(bash.fs, resolved) do
        {:ok, content} -> content
        {:error, _} -> ""
      end
    end)
  end

  defp process_content(content, opts) do
    lines = String.split(content, "\n", trim: false)

    lines =
      if List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    spec = opts.field_spec || opts.char_spec || "1"
    ranges = parse_range(spec)

    lines
    |> Enum.map(&process_line(&1, opts, ranges))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> then(fn s -> if s == "", do: "", else: s <> "\n" end)
  end

  defp process_line(line, opts, ranges) do
    if opts.char_spec do
      chars = String.graphemes(line)
      selected = extract_by_ranges(chars, ranges)
      Enum.join(selected)
    else
      if opts.suppress_no_delim and not String.contains?(line, opts.delimiter) do
        nil
      else
        fields = String.split(line, opts.delimiter)
        selected = extract_by_ranges(fields, ranges)
        Enum.join(selected, opts.delimiter)
      end
    end
  end

  defp parse_range(spec) do
    spec
    |> String.split(",")
    |> Enum.flat_map(&parse_range_part/1)
  end

  defp parse_range_part(part) do
    case String.split(part, "-") do
      [single] ->
        case Integer.parse(single) do
          {n, ""} -> [{n, n}]
          _ -> []
        end

      [start_str, ""] ->
        case Integer.parse(start_str) do
          {start, ""} -> [{start, :infinity}]
          _ -> [{1, :infinity}]
        end

      ["", end_str] ->
        case Integer.parse(end_str) do
          {end_n, ""} -> [{1, end_n}]
          _ -> []
        end

      [start_str, end_str] ->
        with {start, ""} <- Integer.parse(start_str),
             {end_n, ""} <- Integer.parse(end_str) do
          [{start, end_n}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp extract_by_ranges(items, ranges) do
    # Track which indices have been selected to avoid duplicates
    # but preserve the actual values (which may have duplicates)
    selected_indices =
      ranges
      |> Enum.flat_map(fn {start, end_n} ->
        start_idx = start - 1
        end_idx = if end_n == :infinity, do: length(items) - 1, else: end_n - 1

        for i <- start_idx..end_idx, i >= 0 and i < length(items), do: i
      end)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(selected_indices, &Enum.at(items, &1))
  end
end
