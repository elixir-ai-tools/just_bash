defmodule JustBash.Commands.Read do
  @moduledoc "The `read` command - read a line from stdin into a variable."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["read"]

  @impl true
  def execute(bash, args, stdin) do
    {_flags, var_names} = parse_flags(args)
    var_name = List.first(var_names) || "REPLY"

    # Check for stdin from pipeline (stored in __STDIN__ for while loops)
    effective_stdin =
      cond do
        stdin != "" -> stdin
        Map.has_key?(bash.env, "__STDIN__") -> Map.get(bash.env, "__STDIN__")
        true -> ""
      end

    # If no input available at all, return exit code 1 (EOF)
    # Note: "" (empty string) means no input. "\n" means one empty line.
    if effective_stdin == "" do
      new_env = Map.put(bash.env, var_name, "")
      {Command.error("", 1), %{bash | env: new_env}}
    else
      # Split into lines and consume the first one
      # "a\nb\n" -> ["a", "b", ""]
      # "a\nb" -> ["a", "b"]  (no trailing newline)
      # "\n" -> ["", ""]  (one empty line)
      # "" -> [""]  (but we already handled "" above)
      lines = String.split(effective_stdin, "\n", parts: 2)

      case lines do
        # Single content with no newline - EOF without newline
        # Bash reads the data but returns exit code 1
        [only_line] ->
          new_env = Map.put(bash.env, var_name, only_line)
          new_env = Map.delete(new_env, "__STDIN__")
          # Return exit code 1 because no newline terminator
          {Command.error("", 1), %{bash | env: new_env}}

        # Line followed by more content (or empty string after final newline)
        [first_line, rest] ->
          new_env = Map.put(bash.env, var_name, first_line)

          new_env =
            if rest == "" do
              # Was a trailing newline - no more content
              Map.delete(new_env, "__STDIN__")
            else
              Map.put(new_env, "__STDIN__", rest)
            end

          {Command.ok(), %{bash | env: new_env}}
      end
    end
  end

  defp parse_flags(args), do: parse_flags(args, %{}, [])

  defp parse_flags(["-r" | rest], flags, vars),
    do: parse_flags(rest, Map.put(flags, :r, true), vars)

  defp parse_flags(["-p", _prompt | rest], flags, vars),
    do: parse_flags(rest, flags, vars)

  defp parse_flags([arg | rest], flags, vars),
    do: parse_flags(rest, flags, vars ++ [arg])

  defp parse_flags([], flags, vars), do: {flags, vars}
end
