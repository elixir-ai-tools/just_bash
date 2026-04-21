defmodule JustBash.Commands.Chmod do
  @moduledoc """
  The `chmod` command - change file mode bits.

  In the virtual filesystem, permission bits are not tracked, so this command
  succeeds silently as long as the target file exists. With `-R` it succeeds
  for directories as well.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs

  @impl true
  def names, do: ["chmod"]

  @impl true
  def execute(bash, args, _stdin) do
    {opts, positional} = parse_args(args)

    case positional do
      [_mode | paths] when paths != [] ->
        check_paths(bash, paths, opts.recursive)

      _ ->
        {Command.error("chmod: missing operand\n"), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{recursive: false}, [])
  end

  defp parse_args([], opts, pos), do: {opts, Enum.reverse(pos)}
  defp parse_args(["-R" | rest], opts, pos), do: parse_args(rest, %{opts | recursive: true}, pos)
  defp parse_args(["-r" | rest], opts, pos), do: parse_args(rest, opts, ["-r" | pos])

  defp parse_args(["--recursive" | rest], opts, pos),
    do: parse_args(rest, %{opts | recursive: true}, pos)

  defp parse_args([arg | rest], opts, pos), do: parse_args(rest, opts, [arg | pos])

  defp check_paths(bash, paths, _recursive) do
    {stderr, exit_code} =
      Enum.reduce(paths, {"", 0}, fn path, {err, code} ->
        resolved = Fs.resolve_path(bash.cwd, path)

        case Fs.stat(bash.fs, resolved) do
          {:ok, _} -> {err, code}
          {:error, _} -> {err <> "chmod: cannot access '#{path}': No such file or directory\n", 1}
        end
      end)

    {Command.result("", stderr, exit_code), bash}
  end
end
