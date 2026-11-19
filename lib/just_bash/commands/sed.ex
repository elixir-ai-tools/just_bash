defmodule JustBash.Commands.Sed do
  @moduledoc """
  The `sed` command - stream editor for filtering and transforming text.

  This module provides a SED implementation supporting:
  - s, y, d, p, a, i, c, r, =, q, Q, z
  - Multi-line editing: n, N, P, D
  - The hold space: h, H, g, G, x
  - `{...}` blocks, `:label` and branches (b, t, T)
  - Line number, `$`, `first~step` and regex addresses (`/re/`, `\\%re%`, `I`)
  - Ranges, including `addr,+N`, `addr,~N` and `0,/re/`
  - In-place editing (-i flag)
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.Sed.{Executor, Parser}
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["sed"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        execute_with_opts(bash, opts, stdin)
    end
  end

  defp execute_with_opts(bash, opts, stdin) do
    if Map.has_key?(opts, :help) do
      {Command.ok(opts.help), bash}
    else
      execute_scripts(bash, opts, stdin)
    end
  end

  defp execute_scripts(bash, opts, stdin) do
    case Parser.parse(opts.scripts, opts.extended_regex, bash.limits) do
      {:error, msg} ->
        {Command.error("sed: #{msg}\n"), bash}

      {:panic, msg} ->
        {Command.error("sed: #{msg}\n", 4), bash}

      {:ok, commands} ->
        execute_commands(bash, commands, opts, stdin)
    end
  end

  defp execute_commands(bash, commands, opts, stdin) do
    if opts.files == [] do
      output = Executor.execute(stdin, commands, executor_opts(bash, opts))
      {Command.ok(output), bash}
    else
      execute_on_files(bash, commands, opts, stdin)
    end
  end

  defp execute_on_files(bash, commands, opts, stdin) do
    case read_and_process_files(bash, opts.files, commands, opts, stdin) do
      {:ok, output, new_bash} ->
        {Command.ok(output), new_bash}

      {:error, msg} ->
        {Command.error(msg), bash}
    end
  end

  # `r FILE` reads from the sandbox's filesystem; a file that cannot be read
  # prints nothing, as in GNU. The deadline bounds programs that loop through
  # branches without reading input.
  defp executor_opts(bash, opts) do
    %{
      silent: opts.silent,
      deadline: deadline(bash),
      read_file: fn path ->
        case FS.read_file(bash.fs, FS.resolve_path(bash.cwd, path)) do
          {:ok, content, _fs} -> {:ok, content}
          {:error, _} -> :error
        end
      end
    }
  end

  defp deadline(%{interpreter: %{deadline: deadline}}), do: deadline
  defp deadline(_bash), do: nil

  defp parse_args(args) do
    {option_args, extra} = StdinOperand.split_end_of_options(args)

    with {:ok, opts} <-
           parse_args(option_args, %{
             scripts: [],
             files: [],
             silent: false,
             in_place: false,
             extended_regex: false
           }) do
      {:ok, %{opts | files: opts.files ++ extra}}
    end
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["--help" | _rest], opts) do
    help = """
    sed - stream editor for filtering and transforming text

    Usage: sed [OPTION]... {script} [input-file]...

    Options:
      -n, --quiet, --silent  suppress automatic printing of pattern space
      -e script              add the script to commands to be executed
      -i, --in-place         edit files in place
      -E, -r, --regexp-extended  use extended regular expressions
          --help             display this help and exit

    Commands:
      s/regexp/replacement/[flags]  substitute
      y/source/dest/                transliterate characters
      d, D                          delete pattern space / its first line
      p, P                          print pattern space / its first line
      n, N                          read / append the next line
      a, i, c TEXT                  append, insert, change
      r FILE                        append the contents of FILE
      h, H, g, G, x                 copy to / append to / from the hold space
      { ... }                       group commands under one address
      :label, b, t, T               label and branches
      =, q, Q, z                    line number, quit, quit silently, zap

    Addresses:
      N                             line number
      $                             last line
      FIRST~STEP                    every STEPth line from FIRST
      /regexp/, \\%regexp%           lines matching regexp (I: ignore case)
      A,B  A,+N  A,~N  0,/re/       ranges
    """

    {:ok, Map.put(opts, :help, help)}
  end

  defp parse_args(["-n" | rest], opts), do: parse_args(rest, %{opts | silent: true})
  defp parse_args(["--quiet" | rest], opts), do: parse_args(rest, %{opts | silent: true})
  defp parse_args(["--silent" | rest], opts), do: parse_args(rest, %{opts | silent: true})

  defp parse_args(["-i" | rest], opts), do: parse_args(rest, %{opts | in_place: true})
  defp parse_args(["--in-place" | rest], opts), do: parse_args(rest, %{opts | in_place: true})

  defp parse_args(["-E" | rest], opts), do: parse_args(rest, %{opts | extended_regex: true})
  defp parse_args(["-r" | rest], opts), do: parse_args(rest, %{opts | extended_regex: true})

  defp parse_args(["--regexp-extended" | rest], opts),
    do: parse_args(rest, %{opts | extended_regex: true})

  defp parse_args(["-e", script | rest], opts) do
    parse_args(rest, %{opts | scripts: opts.scripts ++ [script]})
  end

  defp parse_args(["-ne", script | rest], opts) do
    parse_args(rest, %{opts | silent: true, scripts: opts.scripts ++ [script]})
  end

  defp parse_args(["-" <> flags | rest], opts) when byte_size(flags) > 0 do
    chars = String.graphemes(flags)
    valid_flags = ["n", "i", "E", "r"]

    if Enum.all?(chars, &(&1 in valid_flags)) do
      new_opts = apply_combined_flags(chars, opts)
      parse_args(rest, new_opts)
    else
      unknown = Enum.find(chars, &(&1 not in valid_flags))
      {:error, "sed: invalid option -- '#{unknown}'\n"}
    end
  end

  defp parse_args([arg | rest], opts) do
    if opts.scripts == [] do
      parse_args(rest, %{opts | scripts: [arg]})
    else
      parse_args(rest, %{opts | files: opts.files ++ [arg]})
    end
  end

  defp apply_combined_flags(chars, opts) do
    Enum.reduce(chars, opts, &apply_single_flag/2)
  end

  defp apply_single_flag("n", acc), do: %{acc | silent: true}
  defp apply_single_flag("i", acc), do: %{acc | in_place: true}
  defp apply_single_flag("E", acc), do: %{acc | extended_regex: true}
  defp apply_single_flag("r", acc), do: %{acc | extended_regex: true}

  defp read_and_process_files(bash, files, commands, opts, stdin) do
    if opts.in_place do
      process_files_in_place(bash, files, commands, opts)
    else
      process_files_to_output(bash, files, commands, opts, stdin)
    end
  end

  defp process_files_to_output(bash, files, commands, opts, stdin) do
    result =
      Enum.reduce_while(files, {:ok, "", bash.fs}, fn file, {:ok, acc, fs} ->
        case StdinOperand.read(fs, bash.cwd, file, stdin) do
          {:ok, content, fs} ->
            output = Executor.execute(content, commands, executor_opts(%{bash | fs: fs}, opts))
            {:cont, {:ok, acc <> output, fs}}

          {:error, error} ->
            {:halt, {:error, "sed: #{file}: #{FS.strerror(error)}\n"}}
        end
      end)

    case result do
      {:ok, output, fs} -> {:ok, output, %{bash | fs: fs}}
      {:error, msg} -> {:error, msg}
    end
  end

  defp process_files_in_place(bash, files, commands, opts) do
    result =
      Enum.reduce_while(files, {:ok, bash}, fn file, {:ok, b} ->
        process_single_file_in_place(b, file, commands, opts)
      end)

    case result do
      {:ok, new_bash} -> {:ok, "", new_bash}
      {:error, msg} -> {:error, msg}
    end
  end

  # POSIX reads the trailing slash in `sed -i s/x/y/ f/` as an assertion that
  # `f` is a directory, and `FS.resolve_path/2` normalizes it away — so an
  # in-place edit spelled that way would rewrite the regular file `f`. Real
  # sed never gets that far: `open("f/")` fails with ENOTDIR before any
  # editing, leaving the file alone.
  defp process_single_file_in_place(bash, file, commands, opts) do
    case FS.check_directory_spelling(bash.fs, bash.cwd, file) do
      {:ok, fs} ->
        read_and_edit(%{bash | fs: fs}, file, commands, opts)

      {:error, %VFS.Error{} = error} ->
        {:halt, {:error, "sed: #{file}: #{FS.strerror(error)}\n"}}
    end
  end

  defp read_and_edit(bash, file, commands, opts) do
    resolved = FS.resolve_path(bash.cwd, file)

    case FS.read_file(bash.fs, resolved) do
      {:ok, content, fs} ->
        write_processed_content(%{bash | fs: fs}, resolved, file, content, commands, opts)

      {:error, error} ->
        {:halt, {:error, "sed: #{file}: #{FS.strerror(error)}\n"}}
    end
  end

  defp write_processed_content(bash, resolved, file, content, commands, opts) do
    output = Executor.execute(content, commands, executor_opts(bash, opts))

    with {:ok, fs} <- unlink_symlink_operand(bash.fs, resolved),
         {:ok, new_fs} <- FS.write_file(fs, resolved, output) do
      {:cont, {:ok, %{bash | fs: new_fs}}}
    else
      {:error, _} -> {:halt, {:error, "sed: #{file}: cannot write\n"}}
    end
  end

  # GNU sed -i renames a temp file over the operand, so a symlink
  # operand is replaced by a regular file (the documented "breaks
  # symbolic links" behavior) and the target is left untouched. Without
  # this, FS.write_file would follow the link and edit the target.
  defp unlink_symlink_operand(fs, resolved) do
    case FS.lstat(fs, resolved) do
      {:ok, %VFS.Stat{type: :symlink}, fs} -> FS.rm(fs, resolved)
      {:ok, _stat, fs} -> {:ok, fs}
      {:error, _} -> {:ok, fs}
    end
  end
end
