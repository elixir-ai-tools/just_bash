defmodule JustBash.Commands.Touch do
  @moduledoc "The `touch` command - change file timestamps or create empty files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["touch"]

  @impl true
  def execute(bash, args, _stdin) do
    {new_fs, stderr, exit_code} =
      args
      |> StdinOperand.drop_end_of_options()
      |> Enum.reduce({bash.fs, "", 0}, fn path, acc ->
        touch_file(bash.cwd, path, acc)
      end)

    {Command.result("", stderr, exit_code), %{bash | fs: new_fs}}
  end

  # POSIX reads the trailing slash in `touch f/` as an assertion that `f` is a
  # directory, and `FS.resolve_path/2` normalizes it away — so `touch f/` over
  # a regular file is an error, not the no-op that touching `f` would be.
  # Checked against GNU coreutils 9.11:
  #
  #     $ touch f/     touch: cannot touch 'f/': Not a directory
  #     $ touch nope/  touch: cannot touch 'nope/': No such file or directory
  #     $ touch d/     (exits 0)
  defp touch_file(cwd, path, {fs_acc, err_acc, code_acc}) do
    resolved = FS.resolve_path(cwd, path)

    case FS.check_directory_spelling(fs_acc, cwd, path) do
      {:ok, fs_acc} -> touch_resolved(fs_acc, resolved, path, err_acc, code_acc)
      {:error, %VFS.Error{} = error} -> {fs_acc, err_acc <> touch_failed(path, error), 1}
    end
  end

  defp touch_resolved(fs_acc, resolved, path, err_acc, code_acc) do
    {exists, fs_acc} = FS.exists?(fs_acc, resolved)

    if exists do
      {fs_acc, err_acc, code_acc}
    else
      create_empty_file(fs_acc, resolved, path, err_acc, code_acc)
    end
  end

  defp create_empty_file(fs, resolved, path, err_acc, code_acc) do
    case FS.write_file(fs, resolved, "") do
      {:ok, new_fs} ->
        {new_fs, err_acc, code_acc}

      {:error, %VFS.Error{} = error} ->
        {fs, err_acc <> touch_failed(path, error), 1}
    end
  end

  defp touch_failed(path, error), do: "touch: cannot touch '#{path}': #{FS.strerror(error)}\n"
end
