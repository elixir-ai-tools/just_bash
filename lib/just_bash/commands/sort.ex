defmodule JustBash.Commands.Sort do
  @moduledoc "The `sort` command - sort lines of text files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["sort"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = parse_flags(args)

    content =
      case files do
        [] ->
          stdin

        [file | _] ->
          resolved = InMemoryFs.resolve_path(bash.cwd, file)

          case InMemoryFs.read_file(bash.fs, resolved) do
            {:ok, c} -> c
            {:error, _} -> ""
          end
      end

    lines = String.split(content, "\n", trim: true)

    sorted =
      if flags.n do
        Enum.sort_by(
          lines,
          fn line ->
            case Integer.parse(String.trim(line)) do
              {n, _} -> n
              :error -> 0
            end
          end,
          if(flags.r, do: :desc, else: :asc)
        )
      else
        if flags.r, do: Enum.sort(lines, :desc), else: Enum.sort(lines)
      end

    sorted = if flags.u, do: Enum.uniq(sorted), else: sorted
    output = if sorted != [], do: Enum.join(sorted, "\n") <> "\n", else: ""
    {Command.ok(output), bash}
  end

  defp parse_flags(args), do: parse_flags(args, %{r: false, u: false, n: false}, [])

  defp parse_flags(["-r" | rest], flags, files),
    do: parse_flags(rest, %{flags | r: true}, files)

  defp parse_flags(["-u" | rest], flags, files),
    do: parse_flags(rest, %{flags | u: true}, files)

  defp parse_flags(["-n" | rest], flags, files),
    do: parse_flags(rest, %{flags | n: true}, files)

  defp parse_flags(["-rn" | rest], flags, files),
    do: parse_flags(rest, %{flags | r: true, n: true}, files)

  defp parse_flags(["-nr" | rest], flags, files),
    do: parse_flags(rest, %{flags | r: true, n: true}, files)

  defp parse_flags([arg | rest], flags, files),
    do: parse_flags(rest, flags, files ++ [arg])

  defp parse_flags([], flags, files), do: {flags, files}
end
