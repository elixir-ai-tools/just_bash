defmodule JustBash.Commands.Stat do
  @moduledoc "The `stat` command - display file status."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["stat"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        if opts.files == [] do
          {Command.error("stat: missing operand\n"), bash}
        else
          {output, stderr, has_error} =
            Enum.reduce(opts.files, {"", "", false}, fn file, {acc_out, acc_err, acc_has_err} ->
              resolved = InMemoryFs.resolve_path(bash.cwd, file)

              case InMemoryFs.stat(bash.fs, resolved) do
                {:ok, stat_info} ->
                  out = format_stat(file, stat_info, opts.format)
                  {acc_out <> out, acc_err, acc_has_err}

                {:error, _} ->
                  err = "stat: cannot stat '#{file}': No such file or directory\n"
                  {acc_out, acc_err <> err, true}
              end
            end)

          exit_code = if has_error, do: 1, else: 0
          {%{stdout: output, stderr: stderr, exit_code: exit_code}, bash}
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{format: nil, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-c", format | rest], opts) do
    parse_args(rest, %{opts | format: format})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "stat: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp format_stat(file, stat_info, nil) do
    mode_octal = Integer.to_string(stat_info.mode, 8) |> String.pad_leading(4, "0")
    mode_str = format_mode_string(stat_info.mode, stat_info.is_directory)
    size = stat_info.size
    blocks = div(size + 511, 512)
    mtime = DateTime.to_iso8601(stat_info.mtime)

    """
      File: #{file}
      Size: #{size}\t\tBlocks: #{blocks}
    Access: (#{mode_octal}/#{mode_str})
    Modify: #{mtime}
    """
  end

  defp format_stat(file, stat_info, format) do
    mode_octal = Integer.to_string(stat_info.mode, 8)
    mode_str = format_mode_string(stat_info.mode, stat_info.is_directory)
    file_type = if stat_info.is_directory, do: "directory", else: "regular file"

    format
    |> String.replace("%n", file)
    |> String.replace("%N", "'#{file}'")
    |> String.replace("%s", Integer.to_string(stat_info.size))
    |> String.replace("%F", file_type)
    |> String.replace("%a", mode_octal)
    |> String.replace("%A", mode_str)
    |> String.replace("%u", "1000")
    |> String.replace("%U", "user")
    |> String.replace("%g", "1000")
    |> String.replace("%G", "group")
    |> Kernel.<>("\n")
  end

  defp format_mode_string(mode, is_directory) do
    type_char = if is_directory, do: "d", else: "-"

    perms = [
      if(Bitwise.band(mode, 0o400) != 0, do: "r", else: "-"),
      if(Bitwise.band(mode, 0o200) != 0, do: "w", else: "-"),
      if(Bitwise.band(mode, 0o100) != 0, do: "x", else: "-"),
      if(Bitwise.band(mode, 0o040) != 0, do: "r", else: "-"),
      if(Bitwise.band(mode, 0o020) != 0, do: "w", else: "-"),
      if(Bitwise.band(mode, 0o010) != 0, do: "x", else: "-"),
      if(Bitwise.band(mode, 0o004) != 0, do: "r", else: "-"),
      if(Bitwise.band(mode, 0o002) != 0, do: "w", else: "-"),
      if(Bitwise.band(mode, 0o001) != 0, do: "x", else: "-")
    ]

    type_char <> Enum.join(perms)
  end
end
