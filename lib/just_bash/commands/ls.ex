defmodule JustBash.Commands.Ls do
  @moduledoc "The `ls` command - list directory contents."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["ls"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, paths} = parse_flags(args)
    paths = if paths == [], do: ["."], else: paths

    {stdout, stderr, exit_code} =
      Enum.reduce(paths, {"", "", 0}, fn path, {out_acc, err_acc, code_acc} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, path)

        case InMemoryFs.readdir(bash.fs, resolved) do
          {:ok, entries} ->
            filtered =
              if flags.a do
                [".", ".." | entries]
              else
                Enum.reject(entries, &String.starts_with?(&1, "."))
              end

            formatted =
              if flags.l do
                Enum.map_join(filtered, "\n", &format_entry(bash.fs, resolved, &1))
              else
                Enum.join(filtered, "\n")
              end

            formatted = if formatted != "", do: formatted <> "\n", else: ""
            {out_acc <> formatted, err_acc, code_acc}

          {:error, :enoent} ->
            {out_acc, err_acc <> "ls: cannot access '#{path}': No such file or directory\n", 1}

          {:error, :enotdir} ->
            case InMemoryFs.stat(bash.fs, resolved) do
              {:ok, _} -> {out_acc <> path <> "\n", err_acc, code_acc}
              _ -> {out_acc, err_acc <> "ls: cannot access '#{path}': Not a directory\n", 1}
            end
        end
      end)

    {Command.result(stdout, stderr, exit_code), bash}
  end

  defp parse_flags(args), do: parse_flags(args, %{a: false, l: false}, [])

  defp parse_flags(["-a" | rest], flags, paths),
    do: parse_flags(rest, %{flags | a: true}, paths)

  defp parse_flags(["-l" | rest], flags, paths),
    do: parse_flags(rest, %{flags | l: true}, paths)

  defp parse_flags(["-la" | rest], flags, paths),
    do: parse_flags(rest, %{flags | l: true, a: true}, paths)

  defp parse_flags(["-al" | rest], flags, paths),
    do: parse_flags(rest, %{flags | l: true, a: true}, paths)

  defp parse_flags([arg | rest], flags, paths), do: parse_flags(rest, flags, paths ++ [arg])
  defp parse_flags([], flags, paths), do: {flags, paths}

  defp format_entry(fs, dir, name) do
    path = InMemoryFs.resolve_path(dir, name)

    case InMemoryFs.stat(fs, path) do
      {:ok, stat} ->
        type = if stat.is_directory, do: "d", else: "-"
        mode = format_mode(stat.mode)
        size = stat.size
        "#{type}#{mode} #{size} #{name}"

      {:error, _} ->
        name
    end
  end

  defp format_mode(mode) do
    r = if Bitwise.band(mode, 0o400) != 0, do: "r", else: "-"
    w = if Bitwise.band(mode, 0o200) != 0, do: "w", else: "-"
    x = if Bitwise.band(mode, 0o100) != 0, do: "x", else: "-"
    "#{r}#{w}#{x}------"
  end
end
