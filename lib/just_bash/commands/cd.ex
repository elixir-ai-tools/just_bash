defmodule JustBash.Commands.Cd do
  @moduledoc "The `cd` command - change directory."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["cd"]

  @impl true
  def execute(bash, args, _stdin) do
    target =
      case args do
        [] -> Map.get(bash.env, "HOME", "/")
        ["-"] -> Map.get(bash.env, "OLDPWD", bash.cwd)
        [path | _] -> path
      end

    resolved = InMemoryFs.resolve_path(bash.cwd, target)

    case InMemoryFs.stat(bash.fs, resolved) do
      {:ok, %{is_directory: true}} ->
        new_env =
          bash.env
          |> Map.put("OLDPWD", bash.cwd)
          |> Map.put("PWD", resolved)

        stdout = if args == ["-"], do: resolved <> "\n", else: ""
        {Command.ok(stdout), %{bash | cwd: resolved, env: new_env}}

      {:ok, _} ->
        {Command.error("bash: cd: #{target}: Not a directory\n"), bash}

      {:error, :enoent} ->
        {Command.error("bash: cd: #{target}: No such file or directory\n"), bash}
    end
  end
end
