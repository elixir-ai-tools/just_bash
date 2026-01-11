defmodule JustBash.Commands.Uniq do
  @moduledoc "The `uniq` command - report or omit repeated lines."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["uniq"]

  @impl true
  def execute(bash, args, stdin) do
    count_flag = "-c" in args
    files = Enum.reject(args, &String.starts_with?(&1, "-"))

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
      if count_flag do
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
