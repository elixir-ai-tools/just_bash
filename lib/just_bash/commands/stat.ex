defmodule JustBash.Commands.Stat do
  @moduledoc "The `stat` command - display file status."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["stat"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        execute_stat(bash, opts)
    end
  end

  defp execute_stat(bash, %{files: []}), do: {Command.error("stat: missing operand\n"), bash}

  defp execute_stat(bash, opts) do
    {output, stderr, has_error, fs} =
      Enum.reduce(opts.files, {"", "", false, bash.fs}, fn file, acc ->
        {_out, _err, _has_err, fs} = acc
        resolved = FS.resolve_path(bash.cwd, file)
        stat_result = FS.stat(fs, resolved)
        accumulate_stat_result(stat_result, file, opts.format, acc)
      end)

    exit_code = if has_error, do: 1, else: 0
    {%{stdout: output, stderr: stderr, exit_code: exit_code}, %{bash | fs: fs}}
  end

  defp accumulate_stat_result(
         {:ok, stat_info, fs},
         file,
         format,
         {acc_out, acc_err, acc_has_err, _fs}
       ) do
    out = format_stat(file, stat_info, format)
    {acc_out <> out, acc_err, acc_has_err, fs}
  end

  defp accumulate_stat_result(
         {:error, error},
         file,
         _format,
         {acc_out, acc_err, _acc_has_err, fs}
       ) do
    err = "stat: cannot stat '#{file}': #{FS.strerror(error)}\n"
    {acc_out, acc_err <> err, true, fs}
  end

  defp parse_args(args) do
    {option_args, extra} = StdinOperand.split_end_of_options(args)

    with {:ok, opts} <- parse_args(option_args, %{format: nil, files: []}) do
      {:ok, %{opts | files: opts.files ++ extra}}
    end
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
    mode = display_mode(stat_info)
    mode_octal = Integer.to_string(mode, 8) |> String.pad_leading(4, "0")
    mode_str = format_mode_string(mode, stat_info.type == :directory)
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
    mode = display_mode(stat_info)
    mode_octal = Integer.to_string(mode, 8)
    mode_str = format_mode_string(mode, stat_info.type == :directory)
    file_type = if stat_info.type == :directory, do: "directory", else: "regular file"

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

  defp display_mode(stat_info) do
    stat_info.mode || if(stat_info.type == :directory, do: 0o755, else: 0o644)
  end

  defp format_mode_string(mode, is_directory) do
    type_char = if is_directory, do: "d", else: "-"

    perm_bits = [
      {0o400, "r"},
      {0o200, "w"},
      {0o100, "x"},
      {0o040, "r"},
      {0o020, "w"},
      {0o010, "x"},
      {0o004, "r"},
      {0o002, "w"},
      {0o001, "x"}
    ]

    perms = Enum.map(perm_bits, fn {bit, char} -> perm_char(mode, bit, char) end)

    type_char <> Enum.join(perms)
  end

  defp perm_char(mode, bit, char) do
    if Bitwise.band(mode, bit) != 0, do: char, else: "-"
  end
end
