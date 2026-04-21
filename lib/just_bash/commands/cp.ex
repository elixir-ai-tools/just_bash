defmodule JustBash.Commands.Cp do
  @moduledoc "The `cp` command - copy files and directories."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["cp"]

  @impl true
  def execute(bash, args, _stdin) do
    {opts, positional} = parse_args(args)

    case positional do
      [src, dest] ->
        do_copy(bash, src, dest, opts)

      _ ->
        {Command.error("cp: missing file operand\n"), bash}
    end
  end

  defp parse_args(args) do
    {opts, positional} =
      Enum.reduce(args, {[], []}, fn
        "-r", {opts, pos} -> {[:recursive | opts], pos}
        "-R", {opts, pos} -> {[:recursive | opts], pos}
        "--recursive", {opts, pos} -> {[:recursive | opts], pos}
        "-a", {opts, pos} -> {[:recursive | opts], pos}
        arg, {opts, pos} -> {opts, pos ++ [arg]}
      end)

    {Enum.uniq(opts), positional}
  end

  defp do_copy(bash, src, dest, opts) do
    src_resolved = FS.resolve_path(bash.cwd, src)
    dest_resolved = FS.resolve_path(bash.cwd, dest)
    recursive = :recursive in opts

    # If dest is an existing directory, copy into it
    dest_final =
      case FS.stat(bash.fs, dest_resolved) do
        {:ok, %{is_directory: true}} ->
          FS.normalize_path(dest_resolved <> "/" <> FS.basename(src_resolved))

        _ ->
          dest_resolved
      end

    cp_opts = if recursive, do: [recursive: true], else: []

    case FS.cp(bash.fs, src_resolved, dest_final, cp_opts) do
      {:ok, new_fs} ->
        {Command.ok(), %{bash | fs: new_fs}}

      {:error, :enoent} ->
        {Command.error("cp: cannot stat '#{src}': No such file or directory\n"), bash}

      {:error, :eisdir} ->
        {Command.error("cp: -r not specified; omitting directory '#{src}'\n"), bash}

      {:error, reason} ->
        {Command.error("cp: #{reason}\n"), bash}
    end
  end
end
