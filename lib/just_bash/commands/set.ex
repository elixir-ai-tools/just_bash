defmodule JustBash.Commands.Set do
  @moduledoc """
  The `set` builtin command - set or unset shell options.

  Supported options:
  - `-e` / `-o errexit`: Exit immediately if a command exits with non-zero status
  - `-u` / `-o nounset`: Treat unset variables as an error
  - `-o pipefail`: Return value of a pipeline is the status of the last command to exit with non-zero status
  - `+e`, `+u`, `+o errexit`, etc.: Unset the option

  Examples:
      set -e           # Enable errexit
      set +e           # Disable errexit
      set -o pipefail  # Enable pipefail
      set -eu          # Enable both errexit and nounset
      set -euo pipefail # Enable all three
  """

  @behaviour JustBash.Commands.Command

  @impl true
  def names, do: ["set"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args, bash.shell_opts) do
      {:ok, new_opts} ->
        new_bash = %{bash | shell_opts: new_opts}
        {%{stdout: "", stderr: "", exit_code: 0}, new_bash}

      {:error, msg} ->
        {%{stdout: "", stderr: "bash: set: #{msg}\n", exit_code: 1}, bash}
    end
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-e" | rest], opts) do
    parse_args(rest, %{opts | errexit: true})
  end

  defp parse_args(["+e" | rest], opts) do
    parse_args(rest, %{opts | errexit: false})
  end

  defp parse_args(["-u" | rest], opts) do
    parse_args(rest, %{opts | nounset: true})
  end

  defp parse_args(["+u" | rest], opts) do
    parse_args(rest, %{opts | nounset: false})
  end

  defp parse_args(["-o", "errexit" | rest], opts) do
    parse_args(rest, %{opts | errexit: true})
  end

  defp parse_args(["+o", "errexit" | rest], opts) do
    parse_args(rest, %{opts | errexit: false})
  end

  defp parse_args(["-o", "nounset" | rest], opts) do
    parse_args(rest, %{opts | nounset: true})
  end

  defp parse_args(["+o", "nounset" | rest], opts) do
    parse_args(rest, %{opts | nounset: false})
  end

  defp parse_args(["-o", "pipefail" | rest], opts) do
    parse_args(rest, %{opts | pipefail: true})
  end

  defp parse_args(["+o", "pipefail" | rest], opts) do
    parse_args(rest, %{opts | pipefail: false})
  end

  defp parse_args(["-o", opt | _rest], _opts) do
    {:error, "invalid option name: #{opt}"}
  end

  defp parse_args(["+o", opt | _rest], _opts) do
    {:error, "invalid option name: #{opt}"}
  end

  # Handle combined options like -eu, -euo
  defp parse_args([<<"-", chars::binary>> | rest], opts) when byte_size(chars) > 1 do
    case parse_combined_opts(chars, opts, true) do
      {:ok, new_opts, remaining} ->
        parse_args(remaining ++ rest, new_opts)

      {:error, _} = err ->
        err
    end
  end

  defp parse_args([<<"+"::binary, chars::binary>> | rest], opts) when byte_size(chars) > 1 do
    case parse_combined_opts(chars, opts, false) do
      {:ok, new_opts, remaining} ->
        parse_args(remaining ++ rest, new_opts)

      {:error, _} = err ->
        err
    end
  end

  defp parse_args([arg | _rest], _opts) do
    {:error, "invalid option: #{arg}"}
  end

  defp parse_combined_opts("", opts, _enable), do: {:ok, opts, []}

  defp parse_combined_opts("e" <> rest, opts, enable) do
    parse_combined_opts(rest, %{opts | errexit: enable}, enable)
  end

  defp parse_combined_opts("u" <> rest, opts, enable) do
    parse_combined_opts(rest, %{opts | nounset: enable}, enable)
  end

  defp parse_combined_opts("o" <> rest, opts, enable) do
    # -o requires a separate argument
    # If rest is empty, the option name will come from the next argument
    # If rest is not empty (e.g., -opipefail), use rest as the option name
    if rest == "" do
      {:ok, opts, [if(enable, do: "-o", else: "+o")]}
    else
      {:ok, opts, [if(enable, do: "-o", else: "+o"), rest]}
    end
  end

  defp parse_combined_opts(<<c::utf8, _rest::binary>>, _opts, _enable) do
    {:error, "invalid option: -#{<<c::utf8>>}"}
  end
end
