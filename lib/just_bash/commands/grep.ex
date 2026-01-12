defmodule JustBash.Commands.Grep do
  @moduledoc "The `grep` command - print lines matching a pattern."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs.InMemoryFs

  @flag_spec %{
    boolean: [:i, :v, :e_ext, :f_fixed, :c, :l, :n, :o, :q, :w, :x, :with_filename, :no_filename],
    aliases: %{"E" => :e_ext, "F" => :f_fixed, "H" => :with_filename, "h" => :no_filename},
    value: [],
    defaults: %{
      i: false,
      v: false,
      e_ext: false,
      f_fixed: false,
      c: false,
      l: false,
      n: false,
      o: false,
      q: false,
      w: false,
      x: false,
      with_filename: false,
      no_filename: false
    }
  }

  @impl true
  def names, do: ["grep"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, rest} = FlagParser.parse(args, @flag_spec)

    case rest do
      [pattern | files] when files != [] ->
        regex = compile_pattern(pattern, flags)
        show_filename = flags.with_filename or (length(files) > 1 and not flags.no_filename)

        {results, any_match} =
          Enum.reduce(files, {[], false}, fn file, {acc, had_match} ->
            resolved = InMemoryFs.resolve_path(bash.cwd, file)

            case InMemoryFs.read_file(bash.fs, resolved) do
              {:ok, content} ->
                prefix = if show_filename, do: "#{file}:", else: ""
                lines = process_content(content, regex, flags, prefix)
                matched = lines != []

                result =
                  cond do
                    flags.q -> nil
                    flags.l and matched -> file
                    flags.c -> "#{prefix}#{length(lines)}"
                    matched -> Enum.join(lines, "\n")
                    true -> nil
                  end

                {if(result, do: [result | acc], else: acc), had_match or matched}

              {:error, _} ->
                {acc, had_match}
            end
          end)

        if flags.q do
          {Command.result("", "", if(any_match, do: 0, else: 1)), bash}
        else
          output = results |> Enum.reverse() |> Enum.join("\n")
          output = if output != "", do: output <> "\n", else: ""
          {Command.result(output, "", if(any_match, do: 0, else: 1)), bash}
        end

      [pattern] ->
        regex = compile_pattern(pattern, flags)
        lines = process_content(stdin, regex, flags, "")
        matched = lines != []

        cond do
          flags.q ->
            {Command.result("", "", if(matched, do: 0, else: 1)), bash}

          flags.c ->
            {Command.ok("#{length(lines)}\n"), bash}

          matched ->
            output = Enum.join(lines, "\n") <> "\n"
            {Command.ok(output), bash}

          true ->
            {Command.result("", "", 1), bash}
        end

      _ ->
        {Command.error("grep: missing pattern\n", 2), bash}
    end
  end

  defp compile_pattern(pattern, flags) do
    opts = if flags.i, do: [:caseless], else: []

    regex_pattern =
      cond do
        flags.f_fixed ->
          Regex.escape(pattern)

        flags.w ->
          "\\b" <> pattern <> "\\b"

        flags.x ->
          "^" <> pattern <> "$"

        true ->
          pattern
      end

    case Regex.compile(regex_pattern, opts) do
      {:ok, regex} -> regex
      {:error, _} -> Regex.compile!(Regex.escape(pattern), opts)
    end
  end

  defp grep_line(line, regex, flags, line_num, prefix) do
    matches = Regex.match?(regex, line)
    should_output = if flags.v, do: not matches, else: matches

    if should_output do
      cond do
        flags.o ->
          Regex.scan(regex, line)
          |> List.flatten()
          |> Enum.map(fn match ->
            add_prefix(match, prefix, flags.n, line_num)
          end)

        flags.n ->
          [add_prefix(line, prefix, true, line_num)]

        true ->
          [add_prefix(line, prefix, false, line_num)]
      end
    else
      []
    end
  end

  defp add_prefix(content, prefix, with_line_num, line_num) do
    line_prefix = if with_line_num, do: "#{line_num}:", else: ""
    prefix <> line_prefix <> content
  end

  defp process_content(content, regex, flags, prefix) do
    content
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      grep_line(line, regex, flags, line_num, prefix)
    end)
  end
end
