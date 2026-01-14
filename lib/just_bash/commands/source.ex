defmodule JustBash.Commands.Source do
  @moduledoc """
  The `source` and `.` builtin commands - execute commands from a file in the current shell.

  Unlike executing a script as a subprocess, source runs the commands in the current
  shell environment, so variable assignments and other changes persist.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Fs.InMemoryFs
  alias JustBash.Interpreter.Executor
  alias JustBash.Parser

  @impl true
  def names, do: ["source", "."]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [] ->
        {%{stdout: "", stderr: "bash: source: filename argument required\n", exit_code: 2}, bash}

      [filename | _extra_args] ->
        resolved = InMemoryFs.resolve_path(bash.cwd, filename)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, content} ->
            execute_script_content(bash, content)

          {:error, :enoent} ->
            {%{
               stdout: "",
               stderr: "bash: source: #{filename}: No such file or directory\n",
               exit_code: 1
             }, bash}

          {:error, :eisdir} ->
            {%{stdout: "", stderr: "bash: source: #{filename}: Is a directory\n", exit_code: 1},
             bash}

          {:error, _reason} ->
            {%{stdout: "", stderr: "bash: source: #{filename}: cannot read\n", exit_code: 1},
             bash}
        end
    end
  end

  defp execute_script_content(bash, content) do
    case Parser.parse(content) do
      {:ok, ast} ->
        Executor.execute_script(bash, ast)

      {:error, error} ->
        {%{stdout: "", stderr: "bash: source: #{error.message}\n", exit_code: 1}, bash}
    end
  end
end
