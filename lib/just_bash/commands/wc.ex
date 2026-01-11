defmodule JustBash.Commands.Wc do
  @moduledoc "The `wc` command - print newline, word, and byte counts."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["wc"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = parse_flags(args)

    case files do
      [file] ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            output = format_output(content, file, flags)
            {Command.ok(output), bash}

          {:error, _} ->
            {Command.error("wc: #{file}: No such file or directory\n"), bash}
        end

      [] ->
        output = format_output(stdin, nil, flags)
        {Command.ok(output), bash}
    end
  end

  defp format_output(content, file, flags) do
    lines = length(String.split(content, "\n", trim: true))
    words = length(String.split(content, ~r/\s+/, trim: true))
    bytes = byte_size(content)

    suffix = if file, do: " #{file}\n", else: "\n"

    cond do
      flags.l and not flags.w and not flags.c -> "#{lines}#{suffix}"
      flags.w and not flags.l and not flags.c -> "#{words}#{suffix}"
      flags.c and not flags.l and not flags.w -> "#{bytes}#{suffix}"
      true -> "#{lines} #{words} #{bytes}#{suffix}"
    end
  end

  defp parse_flags(args), do: parse_flags(args, %{l: false, w: false, c: false}, [])

  defp parse_flags(["-l" | rest], flags, files),
    do: parse_flags(rest, %{flags | l: true}, files)

  defp parse_flags(["-w" | rest], flags, files),
    do: parse_flags(rest, %{flags | w: true}, files)

  defp parse_flags(["-c" | rest], flags, files),
    do: parse_flags(rest, %{flags | c: true}, files)

  defp parse_flags([arg | rest], flags, files),
    do: parse_flags(rest, flags, files ++ [arg])

  defp parse_flags([], flags, files), do: {flags, files}
end
