defmodule JustBash.Commands.Tail do
  @moduledoc "The `tail` command - output the last part of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["tail"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = parse_flags(args)
    n = flags.n

    case files do
      [file] ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            lines = String.split(content, "\n", trim: true)
            output = lines |> Enum.take(-n) |> Enum.join("\n")
            output = if output != "", do: output <> "\n", else: output
            {Command.ok(output), bash}

          {:error, _} ->
            {Command.error(
               "tail: cannot open '#{file}' for reading: No such file or directory\n"
             ), bash}
        end

      [] ->
        lines = String.split(stdin, "\n", trim: true)
        output = lines |> Enum.take(-n) |> Enum.join("\n")
        output = if output != "", do: output <> "\n", else: output
        {Command.ok(output), bash}
    end
  end

  defp parse_flags(args), do: parse_flags(args, %{n: 10}, [])

  defp parse_flags(["-n", n | rest], flags, files) do
    case Integer.parse(n) do
      {num, _} -> parse_flags(rest, %{flags | n: num}, files)
      :error -> parse_flags(rest, flags, files)
    end
  end

  defp parse_flags([<<"-", n::binary>> | rest], flags, files) when n != "" do
    case Integer.parse(n) do
      {num, _} -> parse_flags(rest, %{flags | n: num}, files)
      :error -> parse_flags(rest, flags, files ++ ["-" <> n])
    end
  end

  defp parse_flags([arg | rest], flags, files),
    do: parse_flags(rest, flags, files ++ [arg])

  defp parse_flags([], flags, files), do: {flags, files}
end
