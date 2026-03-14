defmodule JustBash.Commands.Type do
  @moduledoc "The `type` command - display information about command type."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.Registry

  @impl true
  def names, do: ["type"]

  @impl true
  def execute(bash, args, _stdin) do
    if args == [] do
      {Command.error("bash: type: usage: type name [name ...]\n", 1), bash}
    else
      {stdout, stderr, all_found} =
        Enum.reduce(args, {"", "", true}, fn name, {out, err, found} ->
          case identify_command(bash, name) do
            {:ok, description} ->
              {out <> description <> "\n", err, found}

            :not_found ->
              {out, err <> "bash: type: #{name}: not found\n", false}
          end
        end)

      exit_code = if all_found, do: 0, else: 1
      {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, bash}
    end
  end

  defp identify_command(bash, name) do
    cond do
      Map.has_key?(bash.functions, name) ->
        {:ok, "#{name} is a function"}

      Registry.builtin?(name) ->
        {:ok, "#{name} is a shell builtin"}

      Map.has_key?(bash.commands, name) ->
        {:ok, "#{name} is #{name}"}

      Registry.exists?(name) ->
        path = find_in_path(bash, name)
        {:ok, "#{name} is #{path}"}

      true ->
        :not_found
    end
  end

  defp find_in_path(bash, name) do
    path_env = Map.get(bash.env, "PATH", "/bin:/usr/bin")

    path_env
    |> String.split(":")
    |> Enum.find_value(fn dir ->
      if dir != "", do: Path.join(dir, name)
    end)
  end
end
