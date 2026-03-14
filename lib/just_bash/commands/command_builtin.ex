defmodule JustBash.Commands.CommandBuiltin do
  @moduledoc """
  The `command` builtin - execute a command or describe it.

  - `command name [args...]` - Execute the command, bypassing any shell function with that name.
    Custom commands and builtins are still resolved.
  - `command -v name` - Print how the command would be resolved (POSIX-compatible).
    Prints the command name if found, nothing if not found. Exit code 0 if all found, 1 otherwise.
  - `command -V name` - Verbose description of the command type.
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Registry

  @impl true
  def names, do: ["command"]

  @impl true
  def execute(bash, args, stdin) do
    case args do
      [] ->
        {%{stdout: "", stderr: "", exit_code: 0}, bash}

      ["-v" | names] ->
        command_v(bash, names)

      ["-V" | names] ->
        command_v_verbose(bash, names)

      [cmd_name | cmd_args] ->
        execute_bypassing_functions(bash, cmd_name, cmd_args, stdin)
    end
  end

  # command -v: print command name if found
  defp command_v(bash, names) do
    {output, all_found} =
      Enum.reduce(names, {"", true}, fn name, {out, found} ->
        case resolve_type(bash, name) do
          nil -> {out, false}
          _type -> {out <> name <> "\n", found}
        end
      end)

    exit_code = if all_found and names != [], do: 0, else: 1
    {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
  end

  # command -V: verbose description
  defp command_v_verbose(bash, names) do
    {stdout, stderr, all_found} =
      Enum.reduce(names, {"", "", true}, fn name, {out, err, found} ->
        case resolve_type(bash, name) do
          nil ->
            {out, err <> "bash: command: #{name}: not found\n", false}

          :function ->
            {out <> "#{name} is a function\n", err, found}

          :custom ->
            {out <> "#{name} is #{name}\n", err, found}

          :builtin ->
            {out <> "#{name} is a shell builtin\n", err, found}
        end
      end)

    exit_code = if all_found and names != [], do: 0, else: 1
    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, bash}
  end

  # Resolve the type of command: :function, :custom, :builtin, or nil
  defp resolve_type(bash, name) do
    cond do
      Map.has_key?(bash.functions, name) -> :function
      Map.has_key?(bash.commands, name) -> :custom
      Registry.exists?(name) -> :builtin
      true -> nil
    end
  end

  # Execute a command bypassing shell functions
  # Dispatch order: custom commands > builtins
  defp execute_bypassing_functions(bash, cmd_name, args, stdin) do
    case Map.get(bash.commands, cmd_name) do
      nil ->
        case Registry.get(cmd_name) do
          nil ->
            {%{stdout: "", stderr: "bash: #{cmd_name}: command not found\n", exit_code: 127},
             bash}

          module ->
            module.execute(bash, args, stdin)
        end

      module ->
        module.execute(bash, args, stdin)
    end
  end
end
