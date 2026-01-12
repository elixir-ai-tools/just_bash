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

        {output, stderr, dir_count, file_count} =
          Enum.reduce(dirs, {"", "", 0, 0}, fn dir, {acc_out, acc_err, acc_dirs, acc_files} ->
            resolved = InMemoryFs.resolve_path(bash.cwd, dir)

            case build_tree(bash.fs, resolved, dir, opts, "", 0) do
              {:ok, out, d, f} ->
                {acc_out <> out, acc_err, acc_dirs + d, acc_files + f}

              {:error, msg} ->
                {acc_out, acc_err <> msg, acc_dirs, acc_files}
            end
          end)

        dir_word = if dir_count == 1, do: "directory", else: "directories"
        file_word = if file_count == 1, do: "file", else: "files"

        summary =
          if opts.dirs_only do
            "\n#{dir_count} #{dir_word}\n"
          else
            "\n#{dir_count} #{dir_word}, #{file_count} #{file_word}\n"
          end

        exit_code = if stderr != "", do: 1, else: 0
        {%{stdout: output <> summary, stderr: stderr, exit_code: exit_code}, bash}
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

  defp parse_args(["-a" | rest], opts) do
    parse_args(rest, %{opts | show_hidden: true})
  end

  defp parse_args(["-d" | rest], opts) do
    parse_args(rest, %{opts | dirs_only: true})
  end

  defp parse_args(["-f" | rest], opts) do
    parse_args(rest, %{opts | full_path: true})
  end

  defp parse_args(["-L", level | rest], opts) do
    case Integer.parse(level) do
      {n, ""} when n >= 0 -> parse_args(rest, %{opts | max_depth: n})
      _ -> {:error, "tree: invalid level '#{level}'\n"}
    end
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "tree: invalid option '#{arg}'\n"}
  end

  defp parse_args([dir | rest], opts) do
    parse_args(rest, %{opts | dirs: opts.dirs ++ [dir]})
  end

  defp build_tree(fs, path, display_path, opts, _prefix, depth) do
    case InMemoryFs.stat(fs, path) do
      {:ok, %{is_directory: false}} ->
        {:ok, "#{display_path}\n", 0, 1}

      {:ok, %{is_directory: true}} ->
        output = "#{display_path}\n"

        if opts.max_depth != nil and depth >= opts.max_depth do
          {:ok, output, 0, 0}
        else
          case InMemoryFs.readdir(fs, path) do
            {:ok, entries} ->
              entries =
                entries
                |> Enum.filter(fn e ->
                  opts.show_hidden or not String.starts_with?(e, ".")
                end)
                |> Enum.sort()

              {tree_output, dir_count, file_count} =
                build_entries(fs, path, entries, opts, "", depth)

              {:ok, output <> tree_output, dir_count, file_count}

            {:error, _} ->
              {:error, "tree: #{display_path}: Permission denied\n"}
          end
        end

      {:error, _} ->
        {:error, "tree: #{display_path}: No such file or directory\n"}
    end
  end

  defp build_entries(fs, parent_path, entries, opts, prefix, depth) do
    entries_count = length(entries)

    entries
    |> Enum.with_index()
    |> Enum.reduce({"", 0, 0}, fn {entry, idx}, {acc_out, acc_dirs, acc_files} ->
      is_last = idx == entries_count - 1
      connector = if is_last, do: "`-- ", else: "|-- "
      child_prefix = prefix <> if is_last, do: "    ", else: "|   "

      entry_path = if parent_path == "/", do: "/#{entry}", else: "#{parent_path}/#{entry}"

      case InMemoryFs.stat(fs, entry_path) do
        {:ok, %{is_directory: true}} ->
          display_name = if opts.full_path, do: entry_path, else: entry
          line = "#{prefix}#{connector}#{display_name}\n"

          if opts.max_depth != nil and depth + 1 >= opts.max_depth do
            {acc_out <> line, acc_dirs + 1, acc_files}
          else
            case InMemoryFs.readdir(fs, entry_path) do
              {:ok, sub_entries} ->
                sub_entries =
                  sub_entries
                  |> Enum.filter(fn e ->
                    opts.show_hidden or not String.starts_with?(e, ".")
                  end)
                  |> Enum.sort()

                {sub_out, sub_dirs, sub_files} =
                  build_entries(fs, entry_path, sub_entries, opts, child_prefix, depth + 1)

                {acc_out <> line <> sub_out, acc_dirs + 1 + sub_dirs, acc_files + sub_files}

              {:error, _} ->
                {acc_out <> line, acc_dirs + 1, acc_files}
            end
          end

        {:ok, %{is_file: true}} ->
          if opts.dirs_only do
            {acc_out, acc_dirs, acc_files}
          else
            display_name = if opts.full_path, do: entry_path, else: entry
            line = "#{prefix}#{connector}#{display_name}\n"
            {acc_out <> line, acc_dirs, acc_files + 1}
          end

        _ ->
          {acc_out, acc_dirs, acc_files}
      end
    end)
  end
end
