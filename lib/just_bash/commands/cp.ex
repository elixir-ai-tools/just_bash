defmodule JustBash.Commands.Cp do
  @moduledoc "The `cp` command - copy files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["cp"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [src, dest] ->
        src_resolved = FS.resolve_path(bash.cwd, src)
        dest_resolved = FS.resolve_path(bash.cwd, dest)

        case FS.read_file(bash.fs, src_resolved) do
          {:ok, content, fs} ->
            {:ok, new_fs} = FS.write_file(fs, dest_resolved, content)
            {Command.ok(), %{bash | fs: new_fs}}

          {:error, _} ->
            {Command.error("cp: cannot stat '#{src}': No such file or directory\n"), bash}
        end

      _ ->
        {Command.error("cp: missing file operand\n"), bash}
    end
  end
end
