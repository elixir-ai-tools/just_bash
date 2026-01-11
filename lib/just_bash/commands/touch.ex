defmodule JustBash.Commands.Touch do
  @moduledoc "The `touch` command - change file timestamps or create empty files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["touch"]

  @impl true
  def execute(bash, args, _stdin) do
    {new_fs, stderr, exit_code} =
      Enum.reduce(args, {bash.fs, "", 0}, fn path, {fs_acc, err_acc, code_acc} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, path)

        if InMemoryFs.exists?(fs_acc, resolved) do
          {fs_acc, err_acc, code_acc}
        else
          case InMemoryFs.write_file(fs_acc, resolved, "") do
            {:ok, new_fs} -> {new_fs, err_acc, code_acc}
            {:error, _} -> {fs_acc, err_acc <> "touch: cannot touch '#{path}'\n", 1}
          end
        end
      end)

    {Command.result("", stderr, exit_code), %{bash | fs: new_fs}}
  end
end
