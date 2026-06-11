defmodule JustBash.Commands.Ls do
  @moduledoc "The `ls` command - list directory contents."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.Fs

  @flag_spec %{
    boolean: [:a, :l, :h, :r, :R, :S, :t, :one],
    value: [],
    defaults: %{a: false, l: false, h: false, r: false, R: false, S: false, t: false, one: false},
    aliases: %{"1" => :one}
  }

  @impl true
  def names, do: ["ls"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, paths} = FlagParser.parse(args, @flag_spec)
    paths = if paths == [], do: ["."], else: paths

    {stdout, stderr, exit_code} =
      Enum.reduce(paths, {"", "", 0}, fn path, acc ->
        list_path(bash, path, flags, acc)
      end)

    {Command.result(stdout, stderr, exit_code), bash}
  end

  defp list_path(bash, path, flags, {out_acc, err_acc, code_acc}) do
    resolved = Fs.resolve_path(bash.cwd, path)

    case Fs.readdir(bash.fs, resolved) do
      {:ok, entries} ->
        formatted = format_entries(bash.fs, resolved, entries, flags)
        {out_acc <> formatted, err_acc, code_acc}

      {:error, :enoent} ->
        {out_acc, err_acc <> "ls: cannot access '#{path}': No such file or directory\n", 1}

      {:error, :enotdir} ->
        handle_not_dir(bash.fs, resolved, path, {out_acc, err_acc, code_acc})
    end
  end

  defp format_entries(fs, resolved, entries, flags) do
    filtered = filter_entries(entries, flags.a)
    formatted = format_filtered(fs, resolved, filtered, flags)
    if formatted != "", do: formatted <> "\n", else: ""
  end

  defp filter_entries(entries, true), do: [".", ".." | entries]
  defp filter_entries(entries, false), do: Enum.reject(entries, &String.starts_with?(&1, "."))

  defp format_filtered(fs, resolved, filtered, %{l: true} = flags) do
    Enum.map_join(filtered, "\n", &format_entry(fs, resolved, &1, flags.h))
  end

  defp format_filtered(_fs, _resolved, filtered, _flags), do: Enum.join(filtered, "\n")

  defp handle_not_dir(fs, resolved, path, {out_acc, err_acc, code_acc}) do
    case Fs.stat(fs, resolved) do
      {:ok, _} -> {out_acc <> path <> "\n", err_acc, code_acc}
      _ -> {out_acc, err_acc <> "ls: cannot access '#{path}': Not a directory\n", 1}
    end
  end

  defp format_entry(fs, dir, name, human_readable) do
    path = Fs.resolve_path(dir, name)

    case Fs.stat(fs, path) do
      {:ok, stat} ->
        type = if stat.is_directory, do: "d", else: "-"
        mode = format_mode(stat.mode)

        size =
          if human_readable, do: format_human_size(stat.size), else: Integer.to_string(stat.size)

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

  defp format_human_size(bytes) do
    cond do
      bytes < 1024 -> Integer.to_string(bytes)
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)}K"
      bytes < 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 1)}M"
      true -> "#{Float.round(bytes / (1024 * 1024 * 1024), 1)}G"
    end
  end
end
