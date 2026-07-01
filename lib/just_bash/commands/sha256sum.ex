defmodule JustBash.Commands.Sha256sum do
  @moduledoc """
  The `sha256sum` command - compute SHA-256 message digests.

  Computes SHA-256 hashes of files in the virtual filesystem using `:crypto.hash/2`.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["sha256sum"]

  @impl true
  def execute(bash, args, stdin) do
    {opts, files} = parse_args(args)

    cond do
      opts.check ->
        check_checksums(bash, files)

      files == [] or files == ["-"] ->
        hash = :crypto.hash(:sha256, stdin) |> Base.encode16(case: :lower)
        {Command.ok("#{hash}  -\n"), bash}

      true ->
        hash_files(bash, files)
    end
  end

  defp parse_args(args) do
    parse_args(args, %{check: false}, [])
  end

  defp parse_args([], opts, files), do: {opts, Enum.reverse(files)}
  defp parse_args(["-c" | rest], opts, files), do: parse_args(rest, %{opts | check: true}, files)

  defp parse_args(["--check" | rest], opts, files),
    do: parse_args(rest, %{opts | check: true}, files)

  defp parse_args([file | rest], opts, files), do: parse_args(rest, opts, [file | files])

  defp hash_files(bash, files) do
    {stdout, stderr, exit_code, fs} =
      Enum.reduce(files, {"", "", 0, bash.fs}, fn file, {out, err, code, fs} ->
        resolved = FS.resolve_path(bash.cwd, file)

        case FS.read_file(fs, resolved) do
          {:ok, content, new_fs} ->
            hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
            {out <> "#{hash}  #{file}\n", err, code, new_fs}

          {:error, _} ->
            {out, err <> "sha256sum: #{file}: No such file or directory\n", 1, fs}
        end
      end)

    {Command.result(stdout, stderr, exit_code), %{bash | fs: fs}}
  end

  defp check_checksums(bash, files) do
    {stdout, stderr, exit_code, fs} =
      Enum.reduce(files, {"", "", 0, bash.fs}, fn file, {out, err, code, fs} ->
        resolved = FS.resolve_path(bash.cwd, file)

        case FS.read_file(fs, resolved) do
          {:ok, content, new_fs} ->
            verify_checksum_file(bash, content, out, err, code, new_fs)

          {:error, _} ->
            {out, err <> "sha256sum: #{file}: No such file or directory\n", 1, fs}
        end
      end)

    {Command.result(stdout, stderr, exit_code), %{bash | fs: fs}}
  end

  defp verify_checksum_file(bash, content, out, err, code, fs) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce({out, err, code, fs}, fn line, {o, e, c, f} ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [expected_hash, file_path] ->
          verify_single_checksum(
            bash,
            expected_hash,
            file_path,
            :sha256,
            "sha256sum",
            {o, e, c, f}
          )

        _ ->
          {o, e <> "sha256sum: invalid line in checksum file\n", 1, f}
      end
    end)
  end

  defp verify_single_checksum(bash, expected_hash, file_path, algorithm, cmd_name, {o, e, c, f}) do
    trimmed = String.trim(file_path)
    resolved = FS.resolve_path(bash.cwd, trimmed)

    case FS.read_file(f, resolved) do
      {:ok, file_content, new_fs} ->
        actual = :crypto.hash(algorithm, file_content) |> Base.encode16(case: :lower)

        if actual == String.downcase(expected_hash),
          do: {o <> "#{trimmed}: OK\n", e, c, new_fs},
          else: {o <> "#{trimmed}: FAILED\n", e, 1, new_fs}

      {:error, _} ->
        {o, e <> "#{cmd_name}: #{trimmed}: No such file or directory\n", 1, f}
    end
  end
end
