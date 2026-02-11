defmodule JustBash.Commands.Mv do
  @moduledoc "The `mv` command - move (rename) files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["mv"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [src, dest] ->
        src_resolved = InMemoryFs.resolve_path(bash.cwd, src)
        dest_resolved = InMemoryFs.resolve_path(bash.cwd, dest)

        dest_final =
          case InMemoryFs.stat(bash.fs, dest_resolved) do
            {:ok, %{is_directory: true}} ->
              InMemoryFs.normalize_path(dest_resolved <> "/" <> InMemoryFs.basename(src_resolved))

            _ ->
              dest_resolved
          end

        if InMemoryFs.normalize_path(src_resolved) == InMemoryFs.normalize_path(dest_final) do
          {Command.result("", "mv: '#{src_resolved}' and '#{dest_final}' are the same file\n", 0),
           bash}
        else
          case InMemoryFs.mv(bash.fs, src_resolved, dest_final) do
            {:ok, new_fs} ->
              {Command.ok(), %{bash | fs: new_fs}}

            {:error, :enoent} ->
              {Command.error("mv: cannot stat '#{src}': No such file or directory\n"), bash}

            {:error, :eisdir} ->
              {Command.error("mv: cannot overwrite directory '#{dest}' with non-directory\n"),
               bash}

            {:error, :enotdir} ->
              {Command.error("mv: cannot move '#{src}' to '#{dest}': Not a directory\n"), bash}
          end
        end

      _ ->
        {Command.error("mv: missing file operand\n"), bash}
    end
  end
end
