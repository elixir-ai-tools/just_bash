defmodule JustBash.Commands.Shasum do
  @moduledoc """
  The `shasum` command - compute SHA message digests (macOS-style).

  Supports `-a` flag to select algorithm: 1 (default), 256, 384, 512.
  Computes hashes of files in the virtual filesystem using `:crypto.hash/2`.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
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

    files = defaults_to_stdin(files)

    if opts.check do
      check_checksums(bash, algorithm, files, stdin)
    else
      hash_files(bash, algorithm, files, stdin)
    end
  end

  # No operand at all is the same request as a lone `-`, for hashing and for
  # `-c`. One `-` among several files is still that operand: `shasum - f`
  # hashes both, labelling the first `-`; `shasum -c -` reads checksum lines
  # from stdin, not a path named `-`.
  defp defaults_to_stdin([]), do: ["-"]
  defp defaults_to_stdin(files), do: files

  defp parse_args(args) do
    {option_args, extra} = StdinOperand.split_end_of_options(args)
    {opts, files} = parse_args(option_args, %{algorithm: "1", check: false}, [])
    {opts, files ++ extra}
  end

  defp parse_args([], opts, files), do: {opts, Enum.reverse(files)}

  defp parse_args(["-a", algo | rest], opts, files),
    do: parse_args(rest, %{opts | algorithm: algo}, files)

  defp parse_args(["-c" | rest], opts, files), do: parse_args(rest, %{opts | check: true}, files)

  defp parse_args(["--check" | rest], opts, files),
    do: parse_args(rest, %{opts | check: true}, files)

  defp parse_args([file | rest], opts, files), do: parse_args(rest, opts, [file | files])

  defp hash_files(bash, algorithm, files, stdin) do
    {stdout, stderr, exit_code, fs} =
      Enum.reduce(files, {"", "", 0, bash.fs}, fn file, {out, err, code, fs} ->
        case StdinOperand.read(fs, bash.cwd, file, stdin) do
          {:ok, content, new_fs} ->
            hash = :crypto.hash(algorithm, content) |> Base.encode16(case: :lower)
            {out <> "#{hash}  #{file}\n", err, code, new_fs}

          {:error, error} ->
            {out, err <> "shasum: #{file}: #{FS.strerror(error)}\n", 1, fs}
        end
      end)

    {Command.result(stdout, stderr, exit_code), %{bash | fs: fs}}
  end

  defp check_checksums(bash, algorithm, files, stdin) do
    {stdout, stderr, exit_code, fs} =
      Enum.reduce(files, {"", "", 0, bash.fs}, fn file, {out, err, code, fs} ->
        case StdinOperand.read(fs, bash.cwd, file, stdin) do
          {:ok, content, new_fs} ->
            verify_checksum_file(bash, algorithm, content, out, err, code, new_fs)

          {:error, error} ->
            {out, err <> "shasum: #{file}: #{FS.strerror(error)}\n", 1, fs}
        end
      end)

    {Command.result(stdout, stderr, exit_code), %{bash | fs: fs}}
  end

  defp verify_checksum_file(bash, algorithm, content, out, err, code, fs) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce({out, err, code, fs}, fn line, {o, e, c, f} ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [expected_hash, file_path] ->
          verify_single_checksum(bash, expected_hash, file_path, algorithm, {o, e, c, f})

        _ ->
          {o, e <> "shasum: invalid line in checksum file\n", 1, f}
      end
    end)
  end

  defp verify_single_checksum(bash, expected_hash, file_path, algorithm, {o, e, c, f}) do
    trimmed = String.trim(file_path)
    resolved = FS.resolve_path(bash.cwd, trimmed)

    case FS.read_file(f, resolved) do
      {:ok, file_content, new_fs} ->
        actual = :crypto.hash(algorithm, file_content) |> Base.encode16(case: :lower)

        if actual == String.downcase(expected_hash),
          do: {o <> "#{trimmed}: OK\n", e, c, new_fs},
          else: {o <> "#{trimmed}: FAILED\n", e, 1, new_fs}

      {:error, error} ->
        {o, e <> "shasum: #{trimmed}: #{FS.strerror(error)}\n", 1, f}
    end
  end
end
