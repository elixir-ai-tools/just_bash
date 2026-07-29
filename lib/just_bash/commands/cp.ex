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
            write_dest(%{bash | fs: fs}, dest_resolved, dest, content)

          {:error, _} ->
            {Command.error("cp: cannot stat '#{src}': No such file or directory\n"), bash}
        end

      _ ->
        {Command.error("cp: missing file operand\n"), bash}
    end
  end

  # The destination may be unwritable for reasons the source read cannot
  # know about — a path component that is a regular file (:enotdir), a
  # destination that is a directory (:eisdir). Report them instead of
  # crashing on the write.
  defp write_dest(bash, dest_resolved, dest, content) do
    case FS.write_file(bash.fs, dest_resolved, content) do
      {:ok, new_fs} ->
        {Command.ok(), %{bash | fs: new_fs}}

      # GNU stats the destination before opening it, so a path component that
      # is a regular file surfaces as `cannot stat`. `cannot create regular
      # file` stays the wording for a destination whose parent is merely
      # missing.
      {:error, %VFS.Error{kind: :enotdir} = error} ->
        {Command.error("cp: cannot stat '#{dest}': #{FS.strerror(error)}\n"), bash}

      {:error, %VFS.Error{} = error} ->
        {Command.error("cp: cannot create regular file '#{dest}': #{FS.strerror(error)}\n"), bash}
    end
  end
end
