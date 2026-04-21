defmodule JustBash.Commands.Realpath do
  @moduledoc """
  The `realpath` command - print the resolved absolute path.

  Resolves `.`, `..`, and symlinks in the virtual filesystem.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["realpath"]

  @impl true
  def execute(bash, args, _stdin) do
    {_opts, paths} = parse_args(args)

    case paths do
      [] ->
        {Command.error("realpath: missing operand\n"), bash}

      _ ->
        {out_parts, err_parts, exit_code} =
          Enum.reduce(paths, {[], [], 0}, fn path, {out, err, code} ->
            resolved = FS.resolve_path(bash.cwd, path)

            case FS.stat(bash.fs, resolved) do
              {:ok, _} ->
                {[out, resolved, "\n"], err, code}

              {:error, _} ->
                {out, [err, "realpath: ", path, ": No such file or directory\n"], 1}
            end
          end)

        {Command.result(
           IO.iodata_to_binary(out_parts),
           IO.iodata_to_binary(err_parts),
           exit_code
         ), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{}, [])
  end

  defp parse_args([], opts, paths), do: {opts, Enum.reverse(paths)}
  # Skip flags like -e, -m, -s, --relative-to, etc.
  defp parse_args(["--" <> _ | rest], opts, paths), do: parse_args(rest, opts, paths)

  defp parse_args(["-" <> _ | rest], opts, paths),
    do: parse_args(rest, opts, paths)

  defp parse_args([path | rest], opts, paths), do: parse_args(rest, opts, [path | paths])
end
