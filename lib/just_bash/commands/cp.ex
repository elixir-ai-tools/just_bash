defmodule JustBash.Commands.Cp do
  @moduledoc "The `cp` command - copy files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Limits

  @impl true
  def names, do: ["cp"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [src, dest] ->
        src_resolved = InMemoryFs.resolve_path(bash.cwd, src)
        dest_resolved = InMemoryFs.resolve_path(bash.cwd, dest)

        case InMemoryFs.read_file(bash.fs, src_resolved) do
          {:ok, content} ->
            case Limits.write_file(bash, dest_resolved, content) do
              {:ok, new_bash} ->
                {Command.ok(), new_bash}

              {:error, reason, new_bash} ->
                {Command.error(Limits.command_write_error("cp", dest, reason)), new_bash}
            end

          {:error, _} ->
            {Command.error("cp: cannot stat '#{src}': No such file or directory\n"), bash}
        end

      _ ->
        {Command.error("cp: missing file operand\n"), bash}
    end
  end
end
