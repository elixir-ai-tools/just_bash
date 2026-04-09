defmodule JustBash.Commands.Chown do
  @moduledoc """
  The `chown` command - change file owner and group.

  In the virtual filesystem, ownership is not tracked, so this command
  succeeds silently as long as the target file exists.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs

  @impl true
  def names, do: ["chown"]

  @impl true
  def execute(bash, args, _stdin) do
    {_opts, positional} = parse_args(args)

    case positional do
      [_owner | paths] when paths != [] ->
        check_paths(bash, paths)

      _ ->
        {Command.error("chown: missing operand\n"), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{recursive: false}, [])
  end

  defp parse_args([], opts, pos), do: {opts, Enum.reverse(pos)}
  defp parse_args(["-R" | rest], opts, pos), do: parse_args(rest, %{opts | recursive: true}, pos)

  defp parse_args(["--recursive" | rest], opts, pos),
    do: parse_args(rest, %{opts | recursive: true}, pos)

  defp parse_args([arg | rest], opts, pos), do: parse_args(rest, opts, [arg | pos])

  defp check_paths(bash, paths) do
    {stderr, exit_code} =
      Enum.reduce(paths, {"", 0}, fn path, {err, code} ->
        resolved = Fs.resolve_path(bash.cwd, path)

        case Fs.stat(bash.fs, resolved) do
          {:ok, _} -> {err, code}
          {:error, _} -> {err <> "chown: cannot access '#{path}': No such file or directory\n", 1}
        end
      end)

    {Command.result("", stderr, exit_code), bash}
  end
end
