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

        case InMemoryFs.read_file(bash.fs, src_resolved) do
          {:ok, content} ->
            {:ok, new_fs} = InMemoryFs.write_file(bash.fs, dest_resolved, content)
            {:ok, new_fs} = InMemoryFs.rm(new_fs, src_resolved)
            {Command.ok(), %{bash | fs: new_fs}}

          {:error, _} ->
            {Command.error("mv: cannot stat '#{src}': No such file or directory\n"), bash}
        end

      _ ->
        {Command.error("mv: missing file operand\n"), bash}
    end
  end
end
