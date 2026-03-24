defmodule JustBash.Commands.Touch do
  @moduledoc "The `touch` command - change file timestamps or create empty files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Limits

  @impl true
  def names, do: ["touch"]

  @impl true
  def execute(bash, args, _stdin) do
    {new_bash, stderr, exit_code} =
      Enum.reduce_while(args, {bash, "", 0}, fn path, acc ->
        touch_file(path, acc)
      end)

    {Command.result("", stderr, exit_code), new_bash}
  end

  defp touch_file(path, {bash_acc, err_acc, code_acc}) do
    resolved = InMemoryFs.resolve_path(bash_acc.cwd, path)

    if InMemoryFs.exists?(bash_acc.fs, resolved) do
      {:cont, {bash_acc, err_acc, code_acc}}
    else
      create_empty_file(bash_acc, resolved, path, err_acc, code_acc)
    end
  end

  defp create_empty_file(bash, resolved, path, err_acc, code_acc) do
    case Limits.write_file(bash, resolved, "") do
      {:ok, new_bash} ->
        {:cont, {new_bash, err_acc, code_acc}}

      {:error, reason, new_bash} ->
        {:halt, {new_bash, err_acc <> Limits.command_write_error("touch", path, reason), 1}}
    end
  end
end
