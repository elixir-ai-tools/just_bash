defmodule JustBash.Commands.Sed do
  @moduledoc """
  The `sed` command - stream editor for filtering and transforming text.

  This module provides a basic SED implementation supporting:
  - Substitute command (s/pattern/replacement/flags)
  - Delete command (d)
  - Print command (p)
  - Line number and regex addresses
  - Address ranges
  - In-place editing (-i flag)
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.Sed.{Parser, Executor}
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["sed"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        if Map.has_key?(opts, :help) do
          {Command.ok(opts.help), bash}
        else
          case Parser.parse(opts.scripts, opts.extended_regex) do
            {:error, msg} ->
              {Command.error("sed: #{msg}\n"), bash}

            {:ok, commands} ->
              if opts.files == [] do
                output = Executor.execute(stdin, commands, opts.silent)
                {Command.ok(output), bash}
              else
                case read_and_process_files(bash, opts.files, commands, opts) do
                  {:ok, output, new_bash} ->
                    {Command.ok(output), new_bash}

                  {:error, msg} ->
                    {Command.error(msg), bash}
                end
              end
          end
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      scripts: [],
      files: [],
      silent: false,
      in_place: false,
      extended_regex: false
    })
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
      d                             delete pattern space
      p                             print pattern space
      
    Addresses:
      N                             line number
      $                             last line
      /regexp/                      lines matching regexp
      N,M                           range from line N to M
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
      new_opts =
        Enum.reduce(chars, opts, fn char, acc ->
          case char do
            "n" -> %{acc | silent: true}
            "i" -> %{acc | in_place: true}
            "E" -> %{acc | extended_regex: true}
            "r" -> %{acc | extended_regex: true}
          end
        end)

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

  defp read_and_process_files(bash, files, commands, opts) do
    if opts.in_place do
      process_files_in_place(bash, files, commands, opts)
    else
      process_files_to_output(bash, files, commands, opts)
    end
  end

  defp process_files_to_output(bash, files, commands, opts) do
    result =
      Enum.reduce_while(files, {:ok, ""}, fn file, {:ok, acc} ->
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            output = Executor.execute(content, commands, opts.silent)
            {:cont, {:ok, acc <> output}}

          {:error, _} ->
            {:halt, {:error, "sed: #{file}: No such file or directory\n"}}
        end
      end)

    case result do
      {:ok, output} -> {:ok, output, bash}
      {:error, msg} -> {:error, msg}
    end
  end

  defp process_files_in_place(bash, files, commands, opts) do
    result =
      Enum.reduce_while(files, {:ok, bash}, fn file, {:ok, b} ->
        resolved = InMemoryFs.resolve_path(b.cwd, file)

        case InMemoryFs.read_file(b.fs, resolved) do
          {:ok, content} ->
            output = Executor.execute(content, commands, opts.silent)

            case InMemoryFs.write_file(b.fs, resolved, output) do
              {:ok, new_fs} ->
                {:cont, {:ok, %{b | fs: new_fs}}}

              {:error, _} ->
                {:halt, {:error, "sed: #{file}: cannot write\n"}}
            end

          {:error, _} ->
            {:halt, {:error, "sed: #{file}: No such file or directory\n"}}
        end
      end)

    case result do
      {:ok, new_bash} -> {:ok, "", new_bash}
      {:error, msg} -> {:error, msg}
    end
  end
end
