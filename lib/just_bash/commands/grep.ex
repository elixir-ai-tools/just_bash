defmodule JustBash.Commands.Grep do
  @moduledoc "The `grep` command - print lines matching a pattern."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["grep"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, rest} = parse_flags(args)

    case rest do
      [pattern | files] when files != [] ->
        regex = compile_pattern(pattern, flags)

        {stdout, exit_code} =
          Enum.reduce(files, {"", 1}, fn file, {out_acc, code_acc} ->
            resolved = InMemoryFs.resolve_path(bash.cwd, file)

            case InMemoryFs.read_file(bash.fs, resolved) do
              {:ok, content} ->
                matching_lines =
                  content
                  |> String.split("\n")
                  |> Enum.filter(fn line ->
                    matches = Regex.match?(regex, line)
                    if flags.v, do: not matches, else: matches
                  end)

                if matching_lines != [] do
                  prefix = if length(files) > 1, do: "#{file}:", else: ""
                  output = Enum.map_join(matching_lines, "\n", &(prefix <> &1))
                  {out_acc <> output <> "\n", 0}
                else
                  {out_acc, code_acc}
                end

              {:error, _} ->
                {out_acc, code_acc}
            end
          end)

        {Command.result(stdout, "", exit_code), bash}

      [pattern] ->
        regex = compile_pattern(pattern, flags)

        matching_lines =
          stdin
          |> String.split("\n")
          |> Enum.filter(fn line ->
            matches = Regex.match?(regex, line)
            if flags.v, do: not matches, else: matches
          end)

        if matching_lines != [] do
          output = Enum.join(matching_lines, "\n") <> "\n"
          {Command.ok(output), bash}
        else
          {Command.result("", "", 1), bash}
        end

      _ ->
        {Command.error("grep: missing pattern\n", 2), bash}
    end
  end

  defp parse_flags(args), do: parse_flags(args, %{i: false, v: false}, [])

  defp parse_flags(["-i" | rest], flags, acc),
    do: parse_flags(rest, %{flags | i: true}, acc)

  defp parse_flags(["-v" | rest], flags, acc),
    do: parse_flags(rest, %{flags | v: true}, acc)

  defp parse_flags([arg | rest], flags, acc),
    do: parse_flags(rest, flags, acc ++ [arg])

  defp parse_flags([], flags, acc), do: {flags, acc}

  defp compile_pattern(pattern, flags) do
    opts = if flags.i, do: [:caseless], else: []
    Regex.compile!(Regex.escape(pattern), opts)
  end
end
