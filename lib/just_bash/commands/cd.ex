defmodule JustBash.Commands.Cd do
  @moduledoc "The `cd` command - change directory."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

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

    resolved = FS.resolve_path(bash.cwd, target)

    case FS.stat(bash.fs, resolved) do
      {:ok, %{type: :directory}, fs} ->
        new_env =
          bash.env
          |> Map.put("OLDPWD", bash.cwd)
          |> Map.put("PWD", resolved)

        stdout = if args == ["-"], do: resolved <> "\n", else: ""
        {Command.ok(stdout), %{bash | cwd: resolved, env: new_env, fs: fs}}

      {:ok, _, fs} ->
        {Command.error("bash: cd: #{target}: Not a directory\n"), %{bash | fs: fs}}

      # Every other resolution failure renders the same way bash does, from
      # the kernel's error name: ENOTDIR for a component that is a regular
      # file, ELOOP for a symlink cycle, and so on. Enumerating only ENOENT
      # here raised a CaseClauseError out of `JustBash.exec/2` instead.
      {:error, %VFS.Error{} = error} ->
        {Command.error("bash: cd: #{target}: #{FS.strerror(error)}\n"), bash}
    end
  end
end
