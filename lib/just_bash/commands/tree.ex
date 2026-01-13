defmodule JustBash.Commands.Tree do
  @moduledoc "The `tree` command - list contents in a tree-like format."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["tree"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        dirs = if opts.dirs == [], do: ["."], else: opts.dirs
        ctx = %{fs: bash.fs, opts: opts}
        {output, stderr, dir_count, file_count} = process_directories(ctx, bash.cwd, dirs)
        summary = format_summary(dir_count, file_count, opts.dirs_only)
        exit_code = if stderr != "", do: 1, else: 0
        {%{stdout: output <> summary, stderr: stderr, exit_code: exit_code}, bash}
    end
  end

  defp format_summary(dir_count, file_count, dirs_only) do
    dir_word = if dir_count == 1, do: "directory", else: "directories"
    file_word = if file_count == 1, do: "file", else: "files"

    if dirs_only do
      "\n#{dir_count} #{dir_word}\n"
    else
      "\n#{dir_count} #{dir_word}, #{file_count} #{file_word}\n"
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      show_hidden: false,
      dirs_only: false,
      max_depth: nil,
      full_path: false,
      dirs: []
    })
  end

  defp parse_args([], opts), do: {:ok, opts}
  defp parse_args(["-a" | rest], opts), do: parse_args(rest, %{opts | show_hidden: true})
  defp parse_args(["-d" | rest], opts), do: parse_args(rest, %{opts | dirs_only: true})
  defp parse_args(["-f" | rest], opts), do: parse_args(rest, %{opts | full_path: true})

  defp parse_args(["-L", level | rest], opts) do
    case Integer.parse(level) do
      {n, ""} when n >= 0 -> parse_args(rest, %{opts | max_depth: n})
      _ -> {:error, "tree: invalid level '#{level}'\n"}
    end
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts),
    do: {:error, "tree: invalid option '#{arg}'\n"}

  defp parse_args([dir | rest], opts), do: parse_args(rest, %{opts | dirs: opts.dirs ++ [dir]})

  defp process_directories(ctx, cwd, dirs) do
    Enum.reduce(dirs, {"", "", 0, 0}, fn dir, acc ->
      process_single_directory(ctx, cwd, dir, acc)
    end)
  end

  defp process_single_directory(ctx, cwd, dir, {acc_out, acc_err, acc_dirs, acc_files}) do
    resolved = InMemoryFs.resolve_path(cwd, dir)

    case build_tree(ctx, resolved, dir, 0) do
      {:ok, out, d, f} -> {acc_out <> out, acc_err, acc_dirs + d, acc_files + f}
      {:error, msg} -> {acc_out, acc_err <> msg, acc_dirs, acc_files}
    end
  end

  defp build_tree(ctx, path, display_path, depth) do
    case InMemoryFs.stat(ctx.fs, path) do
      {:ok, %{is_directory: false}} -> {:ok, "#{display_path}\n", 0, 1}
      {:ok, %{is_directory: true}} -> build_directory_tree(ctx, path, display_path, depth)
      {:error, _} -> {:error, "tree: #{display_path}: No such file or directory\n"}
    end
  end

  defp build_directory_tree(ctx, path, display_path, depth) do
    output = "#{display_path}\n"

    if at_max_depth?(ctx.opts, depth) do
      {:ok, output, 0, 0}
    else
      build_directory_contents(ctx, path, display_path, output, depth)
    end
  end

  defp at_max_depth?(opts, depth), do: opts.max_depth != nil and depth >= opts.max_depth

  defp build_directory_contents(ctx, path, display_path, output, depth) do
    case InMemoryFs.readdir(ctx.fs, path) do
      {:ok, entries} ->
        filtered = filter_and_sort_entries(entries, ctx.opts)
        {tree_output, dir_count, file_count} = build_entries(ctx, path, filtered, "", depth)
        {:ok, output <> tree_output, dir_count, file_count}

      {:error, _} ->
        {:error, "tree: #{display_path}: Permission denied\n"}
    end
  end

  defp filter_and_sort_entries(entries, opts) do
    entries
    |> Enum.filter(fn e -> opts.show_hidden or not String.starts_with?(e, ".") end)
    |> Enum.sort()
  end

  defp build_entries(ctx, parent_path, entries, prefix, depth) do
    entries_count = length(entries)

    entries
    |> Enum.with_index()
    |> Enum.reduce({"", 0, 0}, fn {entry, idx}, acc ->
      entry_ctx = build_entry_context(parent_path, entry, idx, entries_count, prefix)
      build_single_entry(ctx, entry_ctx, depth, acc)
    end)
  end

  defp build_entry_context(parent_path, entry, idx, entries_count, prefix) do
    is_last = idx == entries_count - 1

    %{
      entry: entry,
      entry_path: join_path(parent_path, entry),
      connector: if(is_last, do: "`-- ", else: "|-- "),
      child_prefix: prefix <> if(is_last, do: "    ", else: "|   ")
    }
  end

  defp build_single_entry(ctx, entry_ctx, depth, acc) do
    case InMemoryFs.stat(ctx.fs, entry_ctx.entry_path) do
      {:ok, %{is_directory: true}} -> build_dir_entry(ctx, entry_ctx, depth, acc)
      {:ok, %{is_file: true}} -> build_file_entry(ctx, entry_ctx, acc)
      _ -> acc
    end
  end

  defp join_path("/", entry), do: "/#{entry}"
  defp join_path(path, entry), do: "#{path}/#{entry}"

  defp build_dir_entry(ctx, entry_ctx, depth, {acc_out, acc_dirs, acc_files}) do
    display_name = if ctx.opts.full_path, do: entry_ctx.entry_path, else: entry_ctx.entry

    line =
      "#{entry_ctx.child_prefix |> String.slice(0..-5//1)}#{entry_ctx.connector}#{display_name}\n"

    if at_max_depth?(ctx.opts, depth + 1) do
      {acc_out <> line, acc_dirs + 1, acc_files}
    else
      build_subdirectory(ctx, entry_ctx, depth, acc_out, acc_dirs, acc_files, line)
    end
  end

  defp build_subdirectory(ctx, entry_ctx, depth, acc_out, acc_dirs, acc_files, line) do
    case InMemoryFs.readdir(ctx.fs, entry_ctx.entry_path) do
      {:ok, sub_entries} ->
        filtered = filter_and_sort_entries(sub_entries, ctx.opts)

        {sub_out, sub_dirs, sub_files} =
          build_entries(ctx, entry_ctx.entry_path, filtered, entry_ctx.child_prefix, depth + 1)

        {acc_out <> line <> sub_out, acc_dirs + 1 + sub_dirs, acc_files + sub_files}

      {:error, _} ->
        {acc_out <> line, acc_dirs + 1, acc_files}
    end
  end

  defp build_file_entry(ctx, entry_ctx, {acc_out, acc_dirs, acc_files}) do
    if ctx.opts.dirs_only do
      {acc_out, acc_dirs, acc_files}
    else
      display_name = if ctx.opts.full_path, do: entry_ctx.entry_path, else: entry_ctx.entry
      prefix = entry_ctx.child_prefix |> String.slice(0..-5//1)
      line = "#{prefix}#{entry_ctx.connector}#{display_name}\n"
      {acc_out <> line, acc_dirs, acc_files + 1}
    end
  end
end
