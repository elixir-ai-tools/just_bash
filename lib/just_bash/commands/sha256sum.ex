defmodule JustBash.Commands.Sha256sum do
  @moduledoc """
  The `sha256sum` command - compute SHA-256 message digests.

  Computes SHA-256 hashes of files in the virtual filesystem using `:crypto.hash/2`.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

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
    {stdout, stderr, exit_code} =
      Enum.reduce(files, {"", "", 0}, fn file, {out, err, code} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
            {out <> "#{hash}  #{file}\n", err, code}

          {:error, _} ->
            {out, err <> "sha256sum: #{file}: No such file or directory\n", 1}
        end
      end)

    {Command.result(stdout, stderr, exit_code), bash}
  end

  defp check_checksums(bash, files) do
    {stdout, stderr, exit_code} =
      Enum.reduce(files, {"", "", 0}, fn file, {out, err, code} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            verify_checksum_file(bash, content, out, err, code)

          {:error, _} ->
            {out, err <> "sha256sum: #{file}: No such file or directory\n", 1}
        end
      end)

    {Command.result(stdout, stderr, exit_code), bash}
  end

  defp verify_checksum_file(bash, content, out, err, code) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce({out, err, code}, fn line, {o, e, c} ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [expected_hash, file_path] ->
          verify_single_checksum(bash, expected_hash, file_path, :sha256, "sha256sum", {o, e, c})

        _ ->
          {o, e <> "sha256sum: invalid line in checksum file\n", 1}
      end
    end)
  end

  defp verify_single_checksum(bash, expected_hash, file_path, algorithm, cmd_name, {o, e, c}) do
    trimmed = String.trim(file_path)
    resolved = InMemoryFs.resolve_path(bash.cwd, trimmed)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, file_content} ->
        actual = :crypto.hash(algorithm, file_content) |> Base.encode16(case: :lower)

        if actual == String.downcase(expected_hash),
          do: {o <> "#{trimmed}: OK\n", e, c},
          else: {o <> "#{trimmed}: FAILED\n", e, 1}

      {:error, _} ->
        {o, e <> "#{cmd_name}: #{trimmed}: No such file or directory\n", 1}
    end
  end
end
