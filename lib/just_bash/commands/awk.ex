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
  alias JustBash.Fs.InMemoryFs

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
    case get_content(bash, opts.files, stdin) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, data} ->
        eval_opts = %{
          field_separator: opts.field_separator,
          variables: opts.variables
        }

        output = Evaluator.execute(data, program, eval_opts)
        {Command.ok(output), bash}
    end
  end

  defp get_content(_bash, [], stdin), do: {:ok, stdin}

  defp get_content(bash, files, _stdin) do
    read_files(bash, files)
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
    parse_args(rest, %{opts | field_separator: fs})
  end

  defp parse_args(["-F" <> fs | rest], opts) when fs != "" do
    parse_args(rest, %{opts | field_separator: fs})
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

  defp read_files(bash, files) do
    Enum.reduce_while(files, {:ok, ""}, fn file, {:ok, acc} ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case InMemoryFs.read_file(bash.fs, resolved) do
        {:ok, content} -> {:cont, {:ok, acc <> content}}
        {:error, _} -> {:halt, {:error, "awk: #{file}: No such file or directory\n"}}
      end
    end)
  end
end
