defmodule JustBash.Commands.Which do
  @moduledoc "The `which` command - locate a command."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.Registry
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["which"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        if opts.names == [] do
          {%{stdout: "", stderr: "", exit_code: 1}, bash}
        else
          path_env = Map.get(bash.env, "PATH", "/bin:/usr/bin")
          path_dirs = String.split(path_env, ":")

          {output, all_found} =
            Enum.reduce(opts.names, {"", true}, fn name, {acc_out, acc_found} ->
              paths = find_command(bash.fs, path_dirs, name, opts.show_all)

              if paths == [] do
                {acc_out, false}
              else
                new_out =
                  if opts.silent do
                    acc_out
                  else
                    acc_out <> Enum.join(paths, "\n") <> "\n"
                  end

                {new_out, acc_found}
              end
            end)

          exit_code = if all_found, do: 0, else: 1
          {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{show_all: false, silent: false, names: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-a" | rest], opts) do
    parse_args(rest, %{opts | show_all: true})
  end

  defp parse_args(["-s" | rest], opts) do
    parse_args(rest, %{opts | silent: true})
  end

  defp parse_args(["-as" | rest], opts) do
    parse_args(rest, %{opts | show_all: true, silent: true})
  end

  defp parse_args(["-sa" | rest], opts) do
    parse_args(rest, %{opts | show_all: true, silent: true})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "which: invalid option -- '#{arg}'\n"}
  end

  defp parse_args([name | rest], opts) do
    parse_args(rest, %{opts | names: opts.names ++ [name]})
  end

  defp find_command(fs, path_dirs, name, show_all) do
    results =
      Enum.flat_map(path_dirs, fn dir ->
        if dir == "" do
          []
        else
          full_path = Path.join(dir, name)

          cond do
            Registry.exists?(name) ->
              [full_path]

            file_exists?(fs, full_path) ->
              [full_path]

            true ->
              []
          end
        end
      end)

    if show_all do
      Enum.uniq(results)
    else
      Enum.take(results, 1)
    end
  end

  defp file_exists?(fs, path) do
    case InMemoryFs.stat(fs, path) do
      {:ok, %{is_file: true}} -> true
      _ -> false
    end
  end
end
