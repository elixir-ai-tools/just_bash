defmodule JustBash.Commands.Sort do
  @moduledoc "The `sort` command - sort lines of text files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs.InMemoryFs

  @flag_spec %{
    boolean: [:r, :u, :n],
    value: [],
    defaults: %{r: false, u: false, n: false}
  }

  @impl true
  def names, do: ["sort"]

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
end
