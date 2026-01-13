defmodule JustBash.Commands.Tail do
  @moduledoc "The `tail` command - output the last part of files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs.InMemoryFs

  @flag_spec %{
    boolean: [],
    value: [:n],
    defaults: %{n: 10}
  }

  @impl true
  def names, do: ["tail"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = FlagParser.parse(args, @flag_spec)
    n = flags.n

    case files do
      [file] -> tail_file(bash, file, n)
      [] -> tail_stdin(bash, stdin, n)
    end
  end

  defp tail_file(bash, file, n) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} ->
        output = format_tail_output(content, n)
        {Command.ok(output), bash}

      {:error, _} ->
        {Command.error("tail: cannot open '#{file}' for reading: No such file or directory\n"),
         bash}
    end
  end

  defp tail_stdin(bash, stdin, n) do
    output = format_tail_output(stdin, n)
    {Command.ok(output), bash}
  end

  defp format_tail_output(content, n) do
    lines = String.split(content, "\n", trim: true)
    output = lines |> Enum.take(-n) |> Enum.join("\n")
    if output != "", do: output <> "\n", else: output
  end
end
