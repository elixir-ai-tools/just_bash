defmodule JustBash.Commands.Awk do
  @moduledoc """
  The `awk` command - pattern scanning and processing language.

  This module provides a basic AWK implementation supporting:
  - BEGIN and END blocks
  - Pattern matching (regex and conditions)
  - Field access ($1, $2, etc.)
  - Built-in variables (NR, NF, FS, OFS, ORS)
  - print and printf statements
  - Variable assignment and arithmetic
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Awk.{Evaluator, Parser}
  alias JustBash.Commands.Command
  alias JustBash.Fs

  @impl true
  def names, do: ["awk"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        execute_with_opts(bash, opts, stdin)
    end
  end

  defp execute_with_opts(bash, %{help: help}, _stdin) do
    {Command.ok(help), bash}
  end

  defp execute_with_opts(bash, opts, stdin) do
    case Parser.parse(opts.program) do
      {:error, msg} ->
        {Command.error("awk: #{msg}\n"), bash}

      {:ok, program} ->
        execute_program(bash, opts, stdin, program)
    end
  end

  defp execute_program(bash, opts, stdin, program) do
    case get_file_data(bash, opts.files, stdin) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, file_data} ->
        eval_opts = %{
          field_separator: opts.field_separator,
          variables: opts.variables,
          bash: bash,
          files: file_data
        }

        {output, exit_code, file_outputs, updated_bash} =
          Evaluator.execute(program, eval_opts)

        bash = updated_bash || bash

        # Write any file outputs from print/printf redirections
        bash =
          Enum.reduce(file_outputs, bash, fn {filename, content}, acc_bash ->
            case Fs.write_file(acc_bash.fs, filename, content) do
              {:ok, fs} -> %{acc_bash | fs: fs}
              {:error, _} -> acc_bash
            end
          end)

        result = %{
          stdout: output,
          stderr: "",
          exit_code: exit_code
        }

        {result, bash}
    end
  end

  # Returns {:ok, [{filename, content}, ...]} for multi-file support
  defp get_file_data(_bash, [], stdin), do: {:ok, [{"", stdin}]}

  defp get_file_data(bash, files, _stdin) do
    read_files_with_names(bash, files)
  end

  defp parse_args(args) do
    parse_args(args, %{
      program: nil,
      files: [],
      field_separator: " ",
      variables: %{}
    })
  end

  defp parse_args([], opts) do
    if opts.program == nil do
      {:error, "awk: missing program\n"}
    else
      {:ok, opts}
    end
  end

  defp parse_args(["--help" | _rest], opts) do
    help = """
    awk - pattern scanning and processing language

    Usage: awk [OPTIONS] 'program' [file ...]

    Options:
      -F fs        use fs as the input field separator
      -v var=val   assign value to variable before execution
          --help   display this help and exit

    Program structure:
      pattern { action }
      BEGIN { action }
      END { action }

    Built-in variables:
      $0           entire current line
      $1, $2, ...  fields
      NR           record (line) number
      NF           number of fields
      FS           field separator
      OFS          output field separator
      ORS          output record separator
    """

    {:ok, Map.put(opts, :help, help)}
  end

  defp parse_args(["-F", fs | rest], opts) do
    parse_args(rest, %{opts | field_separator: interpret_escapes(fs)})
  end

  defp parse_args(["-F" <> fs | rest], opts) when fs != "" do
    parse_args(rest, %{opts | field_separator: interpret_escapes(fs)})
  end

  defp parse_args(["-v", var_assign | rest], opts) do
    case String.split(var_assign, "=", parts: 2) do
      [name, value] ->
        parse_args(rest, %{opts | variables: Map.put(opts.variables, name, value)})

      _ ->
        {:error, "awk: invalid -v assignment: #{var_assign}\n"}
    end
  end

  defp parse_args(["-v" <> var_assign | rest], opts) when var_assign != "" do
    case String.split(var_assign, "=", parts: 2) do
      [name, value] ->
        parse_args(rest, %{opts | variables: Map.put(opts.variables, name, value)})

      _ ->
        {:error, "awk: invalid -v assignment: #{var_assign}\n"}
    end
  end

  defp parse_args([arg | rest], opts) do
    if opts.program == nil do
      parse_args(rest, %{opts | program: arg})
    else
      parse_args(rest, %{opts | files: opts.files ++ [arg]})
    end
  end

  defp read_files_with_names(bash, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      resolved = Fs.resolve_path(bash.cwd, file)

      case Fs.read_file(bash.fs, resolved) do
        {:ok, content} -> {:cont, {:ok, acc ++ [{resolved, content}]}}
        {:error, _} -> {:halt, {:error, "awk: #{file}: No such file or directory\n"}}
      end
    end)
  end

  # Interpret common escape sequences in strings (like \t, \n, etc.)
  defp interpret_escapes(str) do
    str
    |> String.replace("\\t", "\t")
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\\", "\\")
  end
end
