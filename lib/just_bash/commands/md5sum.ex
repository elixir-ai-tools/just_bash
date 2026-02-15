defmodule JustBash.Commands.Md5sum do
  @moduledoc "The `md5sum` command - compute MD5 message digest."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["md5sum"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        files = if opts.files == [], do: ["-"], else: opts.files

        if opts.check do
          check_files(bash, files, stdin)
        else
          compute_hashes(bash, files, stdin)
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{check: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-c" | rest], opts) do
    parse_args(rest, %{opts | check: true})
  end

  defp parse_args(["--check" | rest], opts) do
    parse_args(rest, %{opts | check: true})
  end

  defp parse_args(["-b" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["-t" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["--binary" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["--text" | rest], opts), do: parse_args(rest, opts)

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "md5sum: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp compute_hashes(bash, files, stdin) do
    {output, exit_code} =
      Enum.reduce(files, {"", 0}, fn file, {acc_out, acc_code} ->
        case read_file(bash, file, stdin) do
          {:ok, content, _new_bash} ->
            hash = md5(content)
            {acc_out <> "#{hash}  #{file}\n", acc_code}

          {:error, _} ->
            {acc_out <> "md5sum: #{file}: No such file or directory\n", 1}
        end
      end)

    {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
  end

  defp check_files(bash, files, stdin) do
    {output, failed} =
      Enum.reduce(files, {"", 0}, fn file, {acc_out, acc_failed} ->
        case read_file(bash, file, stdin) do
          {:ok, content, _new_bash} ->
            check_content(bash, content, stdin, acc_out, acc_failed)

          {:error, _} ->
            {acc_out, acc_failed}
        end
      end)

    output =
      if failed > 0 do
        suffix = if failed > 1, do: "s", else: ""
        output <> "md5sum: WARNING: #{failed} computed checksum#{suffix} did NOT match\n"
      else
        output
      end

    exit_code = if failed > 0, do: 1, else: 0
    {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
  end

  defp check_content(bash, content, stdin, acc_out, acc_failed) do
    lines = String.split(content, "\n", trim: true)

    Enum.reduce(lines, {acc_out, acc_failed}, fn line, {out, failed} ->
      verify_checksum_line(bash, stdin, line, out, failed)
    end)
  end

  defp verify_checksum_line(bash, stdin, line, out, failed) do
    case Regex.run(~r/^([a-fA-F0-9]+)\s+[* ]?(.+)$/, line) do
      [_, expected_hash, target_file] ->
        verify_file_checksum(bash, stdin, expected_hash, target_file, out, failed)

      _ ->
        {out, failed}
    end
  end

  defp verify_file_checksum(bash, stdin, expected_hash, target_file, out, failed) do
    case read_file(bash, target_file, stdin) do
      {:ok, target_content, _new_bash} ->
        compare_hashes(target_content, expected_hash, target_file, out, failed)

      {:error, _} ->
        {out <> "#{target_file}: FAILED open or read\n", failed + 1}
    end
  end

  defp compare_hashes(content, expected_hash, target_file, out, failed) do
    actual_hash = md5(content)

    if String.downcase(actual_hash) == String.downcase(expected_hash) do
      {out <> "#{target_file}: OK\n", failed}
    else
      {out <> "#{target_file}: FAILED\n", failed + 1}
    end
  end

  defp read_file(bash, "-", stdin), do: {:ok, stdin, bash}

  defp read_file(bash, file, _stdin) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)
    InMemoryFs.read_file(bash, resolved)
  end

  defp md5(content) do
    :crypto.hash(:md5, content)
    |> Base.encode16(case: :lower)
  end
end
