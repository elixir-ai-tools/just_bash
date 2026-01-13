defmodule JustBash.Commands.Env do
  @moduledoc "The `env` command - print environment variables."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["env"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        new_env =
          if opts.ignore_env do
            Map.new(opts.set)
          else
            bash.env
            |> Map.drop(opts.unset)
            |> Map.merge(Map.new(opts.set))
          end

        output =
          new_env
          |> Enum.sort()
          |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
          |> then(fn s -> if s == "", do: "", else: s <> "\n" end)

        {Command.ok(output), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{ignore_env: false, unset: [], set: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-i" | rest], opts) do
    parse_args(rest, %{opts | ignore_env: true})
  end

  defp parse_args(["--ignore-environment" | rest], opts) do
    parse_args(rest, %{opts | ignore_env: true})
  end

  defp parse_args(["-u", name | rest], opts) do
    parse_args(rest, %{opts | unset: opts.unset ++ [name]})
  end

  defp parse_args(["--unset=" <> name | rest], opts) do
    parse_args(rest, %{opts | unset: opts.unset ++ [name]})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "env: invalid option -- '#{arg}'\n"}
  end

  defp parse_args([arg | rest], opts) do
    if String.contains?(arg, "=") do
      [name | value_parts] = String.split(arg, "=")
      value = Enum.join(value_parts, "=")
      parse_args(rest, %{opts | set: opts.set ++ [{name, value}]})
    else
      {:ok, opts}
    end
  end
end
