defmodule JustBash.Commands.Head do
  @moduledoc "The `head` command - output the first part of files."
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
  def names, do: ["head"]

  @impl true
  def execute(bash, args, stdin) do
    {flags, files} = FlagParser.parse(args, @flag_spec)
    n = flags.n

    case files do
      [file] -> head_file(bash, file, n)
      [] -> head_stdin(bash, stdin, n)
    end
  end

  defp head_file(bash, file, n) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash, resolved) do
      {:ok, content, new_bash} ->
        output = format_head_output(content, n)
        {Command.ok(output), new_bash}

      {:error, _} ->
        {Command.error("head: cannot open '#{file}' for reading: No such file or directory\n"),
         bash}
    end
  end

  defp head_stdin(bash, stdin, n) do
    lines = String.split(stdin, "\n")
    output = lines |> Enum.take(n) |> Enum.join("\n")

    output =
      if output != "" and not String.ends_with?(output, "\n"),
        do: output <> "\n",
        else: output

    {Command.ok(output), bash}
  end

  defp format_head_output(content, n) do
    lines = String.split(content, "\n")
    output = lines |> Enum.take(n) |> Enum.join("\n")

    if String.ends_with?(content, "\n") or length(lines) <= n,
      do: output <> "\n",
      else: output
  end
end
