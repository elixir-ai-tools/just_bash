defmodule JustBash.Commands.Shasum do
  @moduledoc """
  The `shasum` command - compute SHA message digests (macOS-style).

  Supports `-a` flag to select algorithm: 1 (default), 256, 384, 512.
  Computes hashes of files in the virtual filesystem using `:crypto.hash/2`.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["shasum"]

  @impl true
  def execute(bash, args, stdin) do
    {opts, files} = parse_args(args)

    algorithm =
      case opts.algorithm do
        "1" -> :sha
        "256" -> :sha256
        "384" -> :sha384
        "512" -> :sha512
        _ -> :sha
      end

    cond do
      opts.check ->
        check_checksums(bash, algorithm, files)

      files == [] or files == ["-"] ->
        hash = :crypto.hash(algorithm, stdin) |> Base.encode16(case: :lower)
        {Command.ok("#{hash}  -\n"), bash}

      true ->
        hash_files(bash, algorithm, files)
    end
  end

  defp parse_args(args) do
    parse_args(args, %{algorithm: "1", check: false}, [])
  end

  defp parse_args([], opts, files), do: {opts, Enum.reverse(files)}

  defp parse_args(["-a", algo | rest], opts, files),
    do: parse_args(rest, %{opts | algorithm: algo}, files)

  defp parse_args(["-c" | rest], opts, files), do: parse_args(rest, %{opts | check: true}, files)

  defp parse_args(["--check" | rest], opts, files),
    do: parse_args(rest, %{opts | check: true}, files)

  defp parse_args([file | rest], opts, files), do: parse_args(rest, opts, [file | files])

  defp hash_files(bash, algorithm, files) do
    {stdout, stderr, exit_code} =
      Enum.reduce(files, {"", "", 0}, fn file, {out, err, code} ->
        resolved = FS.resolve_path(bash.cwd, file)

        case FS.read_file(bash.fs, resolved) do
          {:ok, content} ->
            hash = :crypto.hash(algorithm, content) |> Base.encode16(case: :lower)
            {out <> "#{hash}  #{file}\n", err, code}

          {:error, _} ->
            {out, err <> "shasum: #{file}: No such file or directory\n", 1}
        end
      end)

    {Command.result(stdout, stderr, exit_code), bash}
  end

  defp check_checksums(bash, algorithm, files) do
    {stdout, stderr, exit_code} =
      Enum.reduce(files, {"", "", 0}, fn file, {out, err, code} ->
        resolved = FS.resolve_path(bash.cwd, file)

        case FS.read_file(bash.fs, resolved) do
          {:ok, content} ->
            verify_checksum_file(bash, algorithm, content, out, err, code)

          {:error, _} ->
            {out, err <> "shasum: #{file}: No such file or directory\n", 1}
        end
      end)

    {Command.result(stdout, stderr, exit_code), bash}
  end

  defp verify_checksum_file(bash, algorithm, content, out, err, code) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce({out, err, code}, fn line, {o, e, c} ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [expected_hash, file_path] ->
          verify_single_checksum(bash, expected_hash, file_path, algorithm, {o, e, c})

        _ ->
          {o, e <> "shasum: invalid line in checksum file\n", 1}
      end
    end)
  end

  defp verify_single_checksum(bash, expected_hash, file_path, algorithm, {o, e, c}) do
    trimmed = String.trim(file_path)
    resolved = FS.resolve_path(bash.cwd, trimmed)

    case FS.read_file(bash.fs, resolved) do
      {:ok, file_content} ->
        actual = :crypto.hash(algorithm, file_content) |> Base.encode16(case: :lower)

        if actual == String.downcase(expected_hash),
          do: {o <> "#{trimmed}: OK\n", e, c},
          else: {o <> "#{trimmed}: FAILED\n", e, 1}

      {:error, _} ->
        {o, e <> "shasum: #{trimmed}: No such file or directory\n", 1}
    end
  end
end
