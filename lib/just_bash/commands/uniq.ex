defmodule JustBash.Commands.Uniq do
  @moduledoc "The `uniq` command - report or omit repeated lines."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs.InMemoryFs

  @flag_spec %{
    boolean: [:c],
    value: [],
    defaults: %{c: false}
  }

  @impl true
  def names, do: ["uniq"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = FlagParser.parse(args, @flag_spec)

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

    output =
      if flags.c do
        lines
        |> Enum.chunk_by(& &1)
        |> Enum.map_join("\n", fn chunk -> "#{length(chunk)} #{hd(chunk)}" end)
      else
        lines
        |> Enum.dedup()
        |> Enum.join("\n")
      end

    output = if output != "", do: output <> "\n", else: ""
    {Command.ok(output), bash}
  end
end
