defmodule JustBash.Commands.Sed.Parser do
  @moduledoc """
  Parser for SED scripts.

  Parses SED script strings into command structures that can be
  executed by the Executor.
  """

  @type address :: nil | :last | {:line, pos_integer()} | {:regex, Regex.t()}
  @type substitute_flags :: [:global | :caseless | :print | {:nth, pos_integer()}]
  @type command ::
          :noop
          | :delete
          | :print
          | {:substitute, Regex.t(), String.t(), substitute_flags()}
          | {:append, String.t()}
          | {:insert, String.t()}
          | {:change, String.t()}
          | {:translate, String.t(), String.t()}
  @type sed_command :: %{
          address1: address(),
          address2: address(),
          negated: boolean(),
          command: command()
        }

  @doc """
  Parse SED scripts into command structures.

  Returns `{:ok, commands}` on success or `{:error, message}` on failure.
  """
  @spec parse([String.t()], boolean()) :: {:ok, [sed_command()]} | {:error, String.t()}
  def parse([], _extended), do: {:error, "no script specified"}

  def parse(scripts, extended) do
    commands =
      Enum.flat_map(scripts, fn script ->
        parse_script(script, extended)
      end)

    if Enum.any?(commands, &match?({:error, _}, &1)) do
      error = Enum.find(commands, &match?({:error, _}, &1))
      error
    else
      {:ok, commands}
    end
  end

  defp parse_script(script, extended) do
    script
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(&parse_command(&1, extended))
  end

  defp parse_command(cmd, extended) do
    case parse_address_and_command(cmd, extended) do
      {:ok, result} -> result
      {:error, msg} -> {:error, msg}
    end
  end

  defp parse_address_and_command(cmd, extended) do
    {addr1, addr2, rest} = parse_addresses(cmd, extended)

    # Check for negation modifier (!)
    {negated, rest} = parse_negation(rest)

    case parse_single_command(rest, extended) do
      {:ok, command} ->
        {:ok, %{address1: addr1, address2: addr2, negated: negated, command: command}}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp parse_negation("!" <> rest), do: {true, String.trim_leading(rest)}
  defp parse_negation(rest), do: {false, rest}

  defp parse_addresses(cmd, extended) do
    case cmd do
      "$" <> rest ->
        parse_address_with_optional_range(:last, String.trim_leading(rest), extended)

      "/" <> _rest ->
        parse_regex_first_address(cmd, extended)

      _ ->
        parse_line_number_address(cmd, extended)
    end
  end

  defp parse_address_with_optional_range(addr1, rest, extended) do
    if String.starts_with?(rest, ",") do
      {addr2, rest2} = parse_second_address(String.slice(rest, 1..-1//1), extended)
      {addr1, addr2, rest2}
    else
      {addr1, nil, rest}
    end
  end

  defp parse_regex_first_address(cmd, extended) do
    case parse_regex_address(cmd, extended) do
      {:ok, regex, rest} ->
        parse_address_with_optional_range({:regex, regex}, String.trim_leading(rest), extended)

      {:error, _} ->
        {nil, nil, cmd}
    end
  end

  defp parse_line_number_address(cmd, extended) do
    case Integer.parse(cmd) do
      {n, rest} ->
        parse_address_with_optional_range({:line, n}, String.trim_leading(rest), extended)

      :error ->
        {nil, nil, cmd}
    end
  end

  defp parse_second_address(rest, extended) do
    rest = String.trim_leading(rest)

    case rest do
      "$" <> rest2 ->
        {:last, String.trim_leading(rest2)}

      "/" <> _rest ->
        case parse_regex_address(rest, extended) do
          {:ok, regex, rest2} -> {{:regex, regex}, rest2}
          {:error, _} -> {nil, rest}
        end

      _ ->
        case Integer.parse(rest) do
          {n, rest2} -> {{:line, n}, String.trim_leading(rest2)}
          :error -> {nil, rest}
        end
    end
  end

  defp parse_regex_address(str, extended) do
    case Regex.run(~r{^/([^/]*)/(.*)$}s, str) do
      [_, pattern, rest] ->
        case compile_regex(pattern, [], extended) do
          {:ok, regex} -> {:ok, regex, rest}
          {:error, _} = err -> err
        end

      nil ->
        {:error, "invalid regex address"}
    end
  end

  defp parse_single_command("", _extended), do: {:ok, :noop}
  defp parse_single_command("d", _extended), do: {:ok, :delete}
  defp parse_single_command("p", _extended), do: {:ok, :print}

  defp parse_single_command("s" <> rest, extended) do
    parse_substitute_command(rest, extended)
  end

  # a\ - append text after current line
  defp parse_single_command("a\\" <> rest, _extended) do
    text = String.trim_leading(rest)
    {:ok, {:append, unescape_text(text)}}
  end

  defp parse_single_command("a " <> rest, _extended) do
    {:ok, {:append, unescape_text(rest)}}
  end

  # i\ - insert text before current line
  defp parse_single_command("i\\" <> rest, _extended) do
    text = String.trim_leading(rest)
    {:ok, {:insert, unescape_text(text)}}
  end

  defp parse_single_command("i " <> rest, _extended) do
    {:ok, {:insert, unescape_text(rest)}}
  end

  # c\ - change (replace) current line with text
  defp parse_single_command("c\\" <> rest, _extended) do
    text = String.trim_leading(rest)
    {:ok, {:change, unescape_text(text)}}
  end

  defp parse_single_command("c " <> rest, _extended) do
    {:ok, {:change, unescape_text(rest)}}
  end

  # y/source/dest/ - transliterate characters
  defp parse_single_command("y" <> rest, _extended) do
    parse_translate_command(rest)
  end

  defp parse_single_command(other, _extended) do
    {:error, "unknown command: #{String.first(other)}"}
  end

  defp parse_substitute_command(rest, extended) do
    if String.length(rest) < 1 do
      {:error, "unterminated `s' command"}
    else
      delimiter = String.first(rest)
      rest = String.slice(rest, 1..-1//1)
      parse_substitute_parts(rest, delimiter, extended)
    end
  end

  defp parse_substitute_parts(rest, delimiter, extended) do
    case split_by_delimiter(rest, delimiter) do
      {:ok, pattern, replacement, flags_str} ->
        build_substitute_command(pattern, replacement, flags_str, extended)

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp build_substitute_command(pattern, replacement, flags_str, extended) do
    flags = parse_substitute_flags(flags_str)

    # Empty pattern means "reuse last regex"
    if pattern == "" do
      {:ok, {:substitute, :last_regex, replacement, flags}}
    else
      case compile_regex(pattern, flags, extended) do
        {:ok, regex} ->
          {:ok, {:substitute, regex, replacement, flags}}

        {:error, msg} ->
          {:error, msg}
      end
    end
  end

  defp split_by_delimiter(str, delimiter) do
    parts = split_unescaped(str, delimiter)

    case parts do
      [pattern, replacement | rest] ->
        flags_str = Enum.join(rest, delimiter)
        {:ok, pattern, replacement, flags_str}

      _ ->
        {:error, "unterminated `s' command"}
    end
  end

  defp split_unescaped(str, delimiter) do
    do_split_unescaped(str, delimiter, "", [], false)
  end

  defp do_split_unescaped("", _delimiter, current, acc, _escaped) do
    Enum.reverse([current | acc])
  end

  defp do_split_unescaped(str, delimiter, current, acc, true) do
    {char, rest} = String.split_at(str, 1)
    do_split_unescaped(rest, delimiter, current <> char, acc, false)
  end

  defp do_split_unescaped("\\" <> rest, delimiter, current, acc, false) do
    do_split_unescaped(rest, delimiter, current <> "\\", acc, true)
  end

  defp do_split_unescaped(str, delimiter, current, acc, false) do
    if String.starts_with?(str, delimiter) do
      rest = String.slice(str, String.length(delimiter)..-1//1)
      do_split_unescaped(rest, delimiter, "", [current | acc], false)
    else
      {char, rest} = String.split_at(str, 1)
      do_split_unescaped(rest, delimiter, current <> char, acc, false)
    end
  end

  defp parse_substitute_flags(flags_str) do
    # Check if flags_str starts with a number for nth occurrence
    case Integer.parse(flags_str) do
      {n, rest} when n > 0 ->
        # Parse remaining flags after the number
        other_flags = parse_letter_flags(rest)
        [{:nth, n} | other_flags]

      _ ->
        parse_letter_flags(flags_str)
    end
  end

  defp parse_letter_flags(flags_str) do
    flags_str
    |> String.graphemes()
    |> Enum.reduce([], fn char, acc ->
      case char do
        "g" -> [:global | acc]
        "i" -> [:caseless | acc]
        "p" -> [:print | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Compile a regex pattern with the given flags.
  Converts BRE (Basic Regular Expression) to ERE for Elixir's PCRE engine.
  """
  @spec compile_regex(String.t(), substitute_flags(), boolean()) ::
          {:ok, Regex.t()} | {:error, String.t()}
  def compile_regex(pattern, flags, extended) do
    # Convert BRE to ERE if not in extended mode
    # In BRE: \( \) \{ \} are special, ( ) { } are literal
    # In ERE (and PCRE): ( ) { } are special, \( \) \{ \} are literal
    converted_pattern =
      if extended do
        pattern
      else
        convert_bre_to_ere(pattern)
      end

    regex_opts =
      Enum.filter(
        [
          if(:caseless in flags, do: :caseless)
        ],
        & &1
      )

    case Regex.compile(converted_pattern, regex_opts) do
      {:ok, regex} -> {:ok, regex}
      {:error, {msg, _}} -> {:error, "invalid regex: #{msg}"}
    end
  end

  # Convert Basic Regular Expression to Extended Regular Expression
  # BRE: \( \) for groups, \{ \} for repetition, ( ) { } are literal
  # ERE/PCRE: ( ) for groups, { } for repetition, \( \) \{ \} are literal
  defp convert_bre_to_ere(pattern) do
    pattern
    |> convert_bre_groups()
  end

  defp convert_bre_groups(pattern) do
    # Process character by character, handling escape sequences
    do_convert_bre(pattern, "", false)
  end

  defp do_convert_bre("", acc, _escaped), do: acc

  defp do_convert_bre(<<"\\", rest::binary>>, acc, false) do
    case rest do
      <<"(", rest2::binary>> ->
        # \( in BRE -> ( in ERE (start capture group)
        do_convert_bre(rest2, acc <> "(", false)

      <<")", rest2::binary>> ->
        # \) in BRE -> ) in ERE (end capture group)
        do_convert_bre(rest2, acc <> ")", false)

      <<"{", rest2::binary>> ->
        # \{ in BRE -> { in ERE (start repetition)
        do_convert_bre(rest2, acc <> "{", false)

      <<"}", rest2::binary>> ->
        # \} in BRE -> } in ERE (end repetition)
        do_convert_bre(rest2, acc <> "}", false)

      <<c, rest2::binary>> ->
        # Other escaped characters - keep the backslash
        do_convert_bre(rest2, acc <> "\\" <> <<c>>, false)

      "" ->
        # Trailing backslash
        acc <> "\\"
    end
  end

  defp do_convert_bre(<<"(", rest::binary>>, acc, false) do
    # Literal ( in BRE -> \( in ERE
    do_convert_bre(rest, acc <> "\\(", false)
  end

  defp do_convert_bre(<<")", rest::binary>>, acc, false) do
    # Literal ) in BRE -> \) in ERE
    do_convert_bre(rest, acc <> "\\)", false)
  end

  defp do_convert_bre(<<c, rest::binary>>, acc, false) do
    do_convert_bre(rest, acc <> <<c>>, false)
  end

  defp unescape_text(text) do
    text
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\\", "\\")
  end

  defp parse_translate_command(rest) do
    if String.length(rest) < 1 do
      {:error, "unterminated `y' command"}
    else
      delimiter = String.first(rest)
      rest = String.slice(rest, 1..-1//1)
      parse_translate_parts(rest, delimiter)
    end
  end

  defp parse_translate_parts(rest, delimiter) do
    parts = String.split(rest, delimiter, parts: 3)

    case parts do
      [source, dest | _] when byte_size(source) == byte_size(dest) ->
        {:ok, {:translate, source, dest}}

      [source, dest | _] ->
        {:error,
         "y command requires source and dest of same length (#{byte_size(source)} vs #{byte_size(dest)})"}

      _ ->
        {:error, "unterminated `y' command"}
    end
  end
end
