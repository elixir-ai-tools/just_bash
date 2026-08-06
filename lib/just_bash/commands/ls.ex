defmodule JustBash.Commands.Ls do
  @moduledoc "The `ls` command - list directory contents."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser
  alias JustBash.FS

  @flag_spec %{
    boolean: [:a, :l, :h, :r, :R, :S, :t, :one],
    value: [],
    defaults: %{a: false, l: false, h: false, r: false, R: false, S: false, t: false, one: false},
    aliases: %{"1" => :one}
  }

  @usage "Try 'ls --help' for more information.\n"

  @impl true
  def names, do: ["ls"]

  @impl true
  def execute(bash, args, _stdin) do
    case FlagParser.parse(args, @flag_spec) do
      {:ok, flags, paths} -> list(bash, flags, paths)
      {:error, reason} -> {Command.error(FlagParser.format_error("ls", reason, @usage), 2), bash}
    end
  end

  defp list(bash, flags, paths) do
    paths = if paths == [], do: ["."], else: paths

    {stdout, stderr, exit_code, fs} =
      Enum.reduce(paths, {"", "", 0, bash.fs}, fn path, acc ->
        list_path(bash.cwd, path, flags, acc)
      end)

    {Command.result(stdout, stderr, exit_code), %{bash | fs: fs}}
  end

  defp list_path(cwd, path, flags, {out_acc, err_acc, code_acc, fs}) do
    resolved = FS.resolve_path(cwd, path)

    case FS.readdir(fs, resolved) do
      {:ok, entries, fs} ->
        formatted = format_entries(fs, resolved, entries, flags)
        {out_acc <> formatted, err_acc, code_acc, fs}

      # ENOTDIR is not necessarily an error: `ls file` lists the file itself.
      # It only becomes one when the name cannot be resolved at all.
      {:error, %VFS.Error{kind: :enotdir}} ->
        handle_not_dir(fs, resolved, path, {out_acc, err_acc, code_acc})

      # Any other resolution failure — ENOENT, or ELOOP from a symlink cycle
      # — is reported with the kernel's wording. Enumerating just those two
      # kinds raised a CaseClauseError out of `JustBash.exec/2`.
      {:error, %VFS.Error{} = error} ->
        {out_acc, err_acc <> "ls: cannot access '#{path}': #{FS.strerror(error)}\n", 1, fs}
    end
  end

  defp format_entries(fs, resolved, entries, flags) do
    filtered = filter_entries(Enum.to_list(entries), flags.a)
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
    case FS.stat(fs, resolved) do
      {:ok, _stat, fs} -> {out_acc <> path <> "\n", err_acc, code_acc, fs}
      _ -> {out_acc, err_acc <> "ls: cannot access '#{path}': Not a directory\n", 1, fs}
    end
  end

  defp format_entry(fs, dir, name, human_readable) do
    path = FS.resolve_path(dir, name)

    case FS.stat(fs, path) do
      {:ok, stat, _fs} ->
        type = if stat.type == :directory, do: "d", else: "-"
        mode = format_mode(stat.mode || if(stat.type == :directory, do: 0o755, else: 0o644))

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
