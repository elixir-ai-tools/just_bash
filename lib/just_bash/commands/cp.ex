defmodule JustBash.Commands.Cp do
  @moduledoc "The `cp` command - copy files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["cp"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [src, dest] ->
        src_resolved = InMemoryFs.resolve_path(bash.cwd, src)
        dest_resolved = InMemoryFs.resolve_path(bash.cwd, dest)

        case InMemoryFs.read_file(bash, src_resolved) do
          {:ok, content, new_bash} ->
            {:ok, new_fs} = InMemoryFs.write_file(new_bash.fs, dest_resolved, content)
            {Command.ok(), %{new_bash | fs: new_fs}}

          {:error, _} ->
            {Command.error("cp: cannot stat '#{src}': No such file or directory\n"), bash}
        end

      _ ->
        {Command.error("cp: missing file operand\n"), bash}
    end
  end
end
