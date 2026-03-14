defmodule JustBash.Commands.Read do
  @moduledoc "The `read` command - read a line from stdin into a variable."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["read"]

  @impl true
  def execute(bash, args, stdin) do
    {_flags, var_names} = parse_flags(args)

    var_names =
      case var_names do
        [] -> ["REPLY"]
        names -> names
      end

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
      new_env = assign_empty(bash.env, var_names)
      {Command.error("", 1), %{bash | env: new_env}}
    else
      # Split into lines and consume the first one
      lines = String.split(effective_stdin, "\n", parts: 2)

      case lines do
        # Single content with no newline - EOF without newline
        # Bash reads the data but returns exit code 1
        [only_line] ->
          new_env = split_and_assign(bash.env, only_line, var_names)
          new_env = Map.delete(new_env, "__STDIN__")
          {Command.error("", 1), %{bash | env: new_env}}

        # Line followed by more content (or empty string after final newline)
        [first_line, rest] ->
          new_env = split_and_assign(bash.env, first_line, var_names)

          new_env =
            if rest == "" do
              Map.delete(new_env, "__STDIN__")
            else
              Map.put(new_env, "__STDIN__", rest)
            end

          {Command.ok(), %{bash | env: new_env}}
      end
    end
  end

  # Split a line on IFS and assign fields to variables.
  # If there are more variables than fields, extra vars get "".
  # If there are more fields than variables, the last var gets the remainder.
  defp split_and_assign(env, line, [single_var]) do
    Map.put(env, single_var, line)
  end

  defp split_and_assign(env, line, var_names) do
    ifs = Map.get(env, "IFS", " \t\n")
    fields = split_on_ifs(line, ifs, length(var_names))
    assign_fields(env, var_names, fields)
  end

  # Split a string on IFS characters into at most `max_fields` parts.
  # The last field gets the unsplit remainder (bash max-split behavior).
  defp split_on_ifs(str, ifs, max_fields) when ifs == "" do
    # Empty IFS means no splitting
    [str | List.duplicate("", max_fields - 1)]
  end

  defp split_on_ifs(str, ifs, max_fields) do
    ifs_chars = String.graphemes(ifs)
    ifs_whitespace = Enum.filter(ifs_chars, &(&1 in [" ", "\t", "\n"]))
    has_ifs_whitespace = ifs_whitespace != []

    # Strip leading/trailing IFS whitespace (bash behavior)
    str =
      if has_ifs_whitespace do
        str
        |> strip_ifs_whitespace(ifs_whitespace, :leading)
        |> strip_ifs_whitespace(ifs_whitespace, :trailing)
      else
        str
      end

    do_split(str, ifs_chars, ifs_whitespace, max_fields, [])
  end

  defp do_split(str, _ifs_chars, _ifs_ws, 1, acc) do
    Enum.reverse([str | acc])
  end

  defp do_split("", _ifs_chars, _ifs_ws, remaining, acc) do
    Enum.reverse(acc) ++ List.duplicate("", remaining)
  end

  defp do_split(str, ifs_chars, ifs_ws, remaining, acc) do
    case find_ifs_delimiter(str, ifs_chars, ifs_ws) do
      nil ->
        # No more delimiters; rest goes into current + pad remaining
        Enum.reverse([str | acc]) ++ List.duplicate("", remaining - 1)

      {field, rest} ->
        do_split(rest, ifs_chars, ifs_ws, remaining - 1, [field | acc])
    end
  end

  # Find the next IFS delimiter and return {field_before, rest_after}.
  # IFS whitespace characters are treated specially: runs of IFS whitespace
  # act as a single delimiter and leading whitespace is skipped.
  defp find_ifs_delimiter(str, ifs_chars, ifs_ws) do
    graphemes = String.graphemes(str)
    find_delim(graphemes, ifs_chars, ifs_ws, [])
  end

  defp find_delim([], _ifs_chars, _ifs_ws, _acc), do: nil

  defp find_delim([char | rest], ifs_chars, ifs_ws, acc) do
    if char in ifs_chars do
      field = acc |> Enum.reverse() |> Enum.join()

      # Skip any adjacent IFS whitespace after a delimiter
      rest = skip_ifs_whitespace(rest, ifs_ws)

      # If the delimiter was a non-whitespace IFS char, also skip trailing IFS ws
      # If next char is also a non-ws IFS char, it creates an empty field (handled by caller)
      {field, Enum.join(rest)}
    else
      find_delim(rest, ifs_chars, ifs_ws, [char | acc])
    end
  end

  defp skip_ifs_whitespace([char | rest], ifs_ws) do
    if char in ifs_ws,
      do: skip_ifs_whitespace(rest, ifs_ws),
      else: [char | rest]
  end

  defp skip_ifs_whitespace([], _ifs_ws), do: []

  defp strip_ifs_whitespace(str, ifs_ws, :leading) do
    str
    |> String.graphemes()
    |> Enum.drop_while(&(&1 in ifs_ws))
    |> Enum.join()
  end

  defp strip_ifs_whitespace(str, ifs_ws, :trailing) do
    str
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in ifs_ws))
    |> Enum.reverse()
    |> Enum.join()
  end

  defp assign_fields(env, [], _fields), do: env
  defp assign_fields(env, _vars, []), do: env

  defp assign_fields(env, [var], [field | _]) do
    Map.put(env, var, field)
  end

  defp assign_fields(env, [var | rest_vars], [field | rest_fields]) do
    env
    |> Map.put(var, field)
    |> assign_fields(rest_vars, rest_fields)
  end

  defp assign_empty(env, var_names) do
    Enum.reduce(var_names, env, fn var, acc -> Map.put(acc, var, "") end)
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
