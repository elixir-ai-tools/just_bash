defmodule JustBash.Commands.Nl do
  @moduledoc "The `nl` command - number lines of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["nl"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        execute_with_opts(bash, opts, stdin)
    end
  end

  defp execute_with_opts(bash, opts, stdin) do
    content = get_content(bash, opts, stdin)
    process_and_return(bash, content, opts)
  end

  defp get_content(_bash, %{files: []}, stdin), do: stdin

  defp get_content(bash, %{files: files}, _stdin) do
    case read_files(bash, files) do
      {:ok, data} -> data
      {:error, msg} -> {:error, msg}
    end
  end

  defp process_and_return(bash, {:error, msg}, _opts), do: {Command.error(msg), bash}

  defp process_and_return(bash, data, opts) do
    output = process_content(data, opts)
    {Command.ok(output), bash}
  end

  defp parse_args(args) do
    parse_args(args, %{
      body_style: :t,
      number_format: :rn,
      width: 6,
      separator: "\t",
      start_number: 1,
      increment: 1,
      files: []
    })
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-b", style | rest], opts) do
    case parse_body_style(style) do
      {:ok, s} -> parse_args(rest, %{opts | body_style: s})
      {:error, msg} -> {:error, msg}
    end
  end

  defp parse_args(["-b" <> style | rest], opts) when style != "" do
    case parse_body_style(style) do
      {:ok, s} -> parse_args(rest, %{opts | body_style: s})
      {:error, msg} -> {:error, msg}
    end
  end

  defp parse_args(["-n", format | rest], opts) do
    case parse_number_format(format) do
      {:ok, f} -> parse_args(rest, %{opts | number_format: f})
      {:error, msg} -> {:error, msg}
    end
  end

  defp parse_args(["-n" <> format | rest], opts) when format != "" do
    case parse_number_format(format) do
      {:ok, f} -> parse_args(rest, %{opts | number_format: f})
      {:error, msg} -> {:error, msg}
    end
  end

  defp parse_args(["-w", width | rest], opts) do
    case Integer.parse(width) do
      {w, ""} when w >= 1 -> parse_args(rest, %{opts | width: w})
      _ -> {:error, "nl: invalid line number field width: '#{width}'\n"}
    end
  end

  defp parse_args(["-w" <> width | rest], opts) when width != "" do
    case Integer.parse(width) do
      {w, ""} when w >= 1 -> parse_args(rest, %{opts | width: w})
      _ -> {:error, "nl: invalid line number field width: '#{width}'\n"}
    end
  end

  defp parse_args(["-s", sep | rest], opts) do
    parse_args(rest, %{opts | separator: sep})
  end

  defp parse_args(["-s" <> sep | rest], opts) when sep != "" do
    parse_args(rest, %{opts | separator: sep})
  end

  defp parse_args(["-v", start | rest], opts) do
    case Integer.parse(start) do
      {s, ""} -> parse_args(rest, %{opts | start_number: s})
      _ -> {:error, "nl: invalid starting line number: '#{start}'\n"}
    end
  end

  defp parse_args(["-v" <> start | rest], opts) when start != "" do
    case Integer.parse(start) do
      {s, ""} -> parse_args(rest, %{opts | start_number: s})
      _ -> {:error, "nl: invalid starting line number: '#{start}'\n"}
    end
  end

  defp parse_args(["-i", incr | rest], opts) do
    case Integer.parse(incr) do
      {i, ""} -> parse_args(rest, %{opts | increment: i})
      _ -> {:error, "nl: invalid line number increment: '#{incr}'\n"}
    end
  end

  defp parse_args(["-i" <> incr | rest], opts) when incr != "" do
    case Integer.parse(incr) do
      {i, ""} -> parse_args(rest, %{opts | increment: i})
      _ -> {:error, "nl: invalid line number increment: '#{incr}'\n"}
    end
  end

  defp parse_args(["--" | rest], opts) do
    {:ok, %{opts | files: opts.files ++ rest}}
  end

  defp parse_args(["--" <> _ = arg | _rest], _opts) do
    {:error, "nl: unrecognized option '#{arg}'\n"}
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "nl: invalid option -- '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp parse_body_style("a"), do: {:ok, :a}
  defp parse_body_style("t"), do: {:ok, :t}
  defp parse_body_style("n"), do: {:ok, :n}
  defp parse_body_style(s), do: {:error, "nl: invalid body numbering style: '#{s}'\n"}

  defp parse_number_format("ln"), do: {:ok, :ln}
  defp parse_number_format("rn"), do: {:ok, :rn}
  defp parse_number_format("rz"), do: {:ok, :rz}
  defp parse_number_format(f), do: {:error, "nl: invalid line numbering format: '#{f}'\n"}

  defp read_files(bash, files) do
    Enum.reduce_while(files, {:ok, ""}, fn file, {:ok, acc} ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case InMemoryFs.read_file(bash, resolved) do
        {:ok, data, _new_bash} -> {:cont, {:ok, acc <> data}}
        {:error, _} -> {:halt, {:error, "nl: #{file}: No such file or directory\n"}}
      end
    end)
  end

  defp process_content("", _opts), do: ""

  defp process_content(content, opts) do
    has_trailing_newline = String.ends_with?(content, "\n")
    lines = String.split(content, "\n", trim: false)

    lines =
      if has_trailing_newline and List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    {result_lines, _final_num} =
      Enum.reduce(lines, {[], opts.start_number}, fn line, {acc, num} ->
        if should_number?(line, opts.body_style) do
          formatted = format_line_number(num, opts.number_format, opts.width)
          new_line = "#{formatted}#{opts.separator}#{line}"
          {acc ++ [new_line], num + opts.increment}
        else
          padding = String.duplicate(" ", opts.width)
          new_line = "#{padding}#{opts.separator}#{line}"
          {acc ++ [new_line], num}
        end
      end)

    output = Enum.join(result_lines, "\n")
    if has_trailing_newline, do: output <> "\n", else: output
  end

  defp should_number?(_line, :a), do: true
  defp should_number?(line, :t), do: String.trim(line) != ""
  defp should_number?(_line, :n), do: false

  defp format_line_number(num, :ln, width) do
    String.pad_trailing(Integer.to_string(num), width)
  end

  defp format_line_number(num, :rn, width) do
    String.pad_leading(Integer.to_string(num), width)
  end

  defp format_line_number(num, :rz, width) do
    String.pad_leading(Integer.to_string(num), width, "0")
  end
end
