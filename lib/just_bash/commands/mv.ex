defmodule JustBash.Commands.Mv do
  @moduledoc "The `mv` command - move (rename) files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["mv"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [src, dest] ->
        src_resolved = FS.resolve_path(bash.cwd, src)
        dest_resolved = FS.resolve_path(bash.cwd, dest)

        {dest_final, fs} =
          case FS.stat(bash.fs, dest_resolved) do
            {:ok, %VFS.Stat{type: :directory}, fs} ->
              {FS.normalize_path(dest_resolved <> "/" <> FS.basename(src_resolved)), fs}

            {:ok, _stat, fs} ->
              {dest_resolved, fs}

            {:error, _} ->
              {dest_resolved, bash.fs}
          end

        bash = %{bash | fs: fs}

        if FS.normalize_path(src_resolved) == FS.normalize_path(dest_final) do
          {Command.result("", "mv: '#{src_resolved}' and '#{dest_final}' are the same file\n", 1),
           bash}
        else
          case FS.mv(bash.fs, src_resolved, dest_final) do
            {:ok, new_fs} ->
              {Command.ok(), %{bash | fs: new_fs}}

            {:error, %VFS.Error{kind: :enoent}} ->
              {Command.error("mv: cannot stat '#{src}': No such file or directory\n"), bash}

            {:error, %VFS.Error{kind: :eisdir}} ->
              {Command.error("mv: cannot overwrite directory '#{dest}' with non-directory\n"),
               bash}

            {:error, %VFS.Error{kind: :enotdir}} ->
              {Command.error("mv: cannot move '#{src}' to '#{dest}': Not a directory\n"), bash}
          end
        end

      _ ->
        {Command.error("mv: missing file operand\n"), bash}
    end
  end
end
