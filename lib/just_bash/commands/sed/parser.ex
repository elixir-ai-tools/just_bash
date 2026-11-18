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

  # Parser context threaded through all functions
  @typep ctx :: %{extended: boolean(), limits: JustBash.Limit.t() | nil}

  @doc """
  Parse SED scripts into command structures.

  Returns `{:ok, commands}` on success or `{:error, message}` on failure.
  """
  @spec parse([String.t()], boolean(), JustBash.Limit.t() | nil) ::
          {:ok, [sed_command()]} | {:error, String.t()}
  def parse(scripts, extended, limits \\ nil)
  def parse([], _extended, _limits), do: {:error, "no script specified"}

  def parse(scripts, extended, limits) do
    ctx = %{extended: extended, limits: limits}

    # GNU joins the scripts of several -e options with newlines before parsing
    # them, so `-e '1a\' -e 'text'` is one append whose text is on the next
    # line, as if the script had been written on two lines.
    commands = scripts |> Enum.join("\n") |> parse_script(ctx)

    if Enum.any?(commands, &match?({:error, _}, &1)) do
      Enum.find(commands, &match?({:error, _}, &1))
    else
      {:ok, commands}
    end
  end

  defp parse_script(script, ctx) do
    script
    |> split_commands([])
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(&parse_command(&1, ctx))
  end

  # Splits a script into its commands at `;` and newlines, as GNU sed does.
  # A separator only counts between commands: a `;` inside an s or y command's
  # delimited parts, inside a /regex/ address, or in a, i or c text (which runs
  # to the end of the line) is part of that command. `s/a/b; c/` is one
  # substitution whose replacement is "b; c", not `s/a/b` followed by a command
  # named "c/".
  defp split_commands("", acc), do: Enum.reverse(acc)

  defp split_commands(script, acc) do
    {address, rest} = take_address(script, "")
    {body, rest} = take_body(rest)
    split_commands(rest, [address <> body | acc])
  end

  # Line numbers, `$`, ranges, negation and /regex/ addresses ahead of the
  # command letter.
  defp take_address(<<c, rest::binary>>, acc) when c in ~c"0123456789$,! \t" do
    take_address(rest, acc <> <<c>>)
  end

  defp take_address("/" <> rest, acc) do
    {regex, rest} = take_delimited(rest, "/", "")
    take_address(rest, acc <> "/" <> regex)
  end

  defp take_address(rest, acc), do: {acc, rest}

  defp take_body(<<cmd, rest::binary>>) when cmd in [?s, ?y] do
    case String.next_grapheme(rest) do
      {delimiter, rest} when delimiter not in ["\n", "\\"] ->
        {first, rest} = take_delimited(rest, delimiter, "")
        {second, rest} = take_delimited(rest, delimiter, "")
        {flags, rest} = take_to_separator(rest, "")
        {<<cmd>> <> delimiter <> first <> second <> flags, rest}

      _ ->
        take_to_separator(<<cmd>> <> rest, "")
    end
  end

  defp take_body(<<cmd, rest::binary>>) when cmd in [?a, ?i, ?c] do
    take_text(rest, <<cmd>>)
  end

  defp take_body(rest), do: take_to_separator(rest, "")

  # One delimited part of an s or y command, or a /regex/ address, up to and
  # including its closing delimiter. A backslash keeps the character after it,
  # so an escaped delimiter does not close the part. An unterminated part takes
  # the rest of the script, and the command parser reports it.
  defp take_delimited("", _delimiter, acc), do: {acc, ""}

  defp take_delimited("\\" <> rest, delimiter, acc) do
    case String.next_grapheme(rest) do
      {char, rest} -> take_delimited(rest, delimiter, acc <> "\\" <> char)
      nil -> {acc <> "\\", ""}
    end
  end

  defp take_delimited(str, delimiter, acc) do
    case String.next_grapheme(str) do
      {^delimiter, rest} -> {acc <> delimiter, rest}
      {char, rest} -> take_delimited(rest, delimiter, acc <> char)
    end
  end

  # Up to a `;` or newline, which is consumed and not returned.
  defp take_to_separator("", acc), do: {acc, ""}
  defp take_to_separator(";" <> rest, acc), do: {acc, rest}
  defp take_to_separator("\n" <> rest, acc), do: {acc, rest}

  defp take_to_separator(<<c, rest::binary>>, acc),
    do: take_to_separator(rest, acc <> <<c>>)

  # The text of an a, i or c command runs to the end of the line, `;`
  # included. In the classic form, `a\` followed by a newline, the text is on
  # the next line, and a backslash at the end of a text line continues it.
  defp take_text("\\\n" <> rest, acc), do: take_text(rest, acc <> "\\\n")
  defp take_text("", acc), do: {acc, ""}
  defp take_text("\n" <> rest, acc), do: {acc, rest}
  defp take_text(<<c, rest::binary>>, acc), do: take_text(rest, acc <> <<c>>)

  defp parse_command(cmd, ctx) do
    case parse_address_and_command(cmd, ctx) do
      {:ok, result} -> result
      {:error, msg} -> {:error, msg}
    end
  end

  defp parse_address_and_command(cmd, ctx) do
    {addr1, addr2, rest} = parse_addresses(cmd, ctx)

    # Check for negation modifier (!)
    {negated, rest} = parse_negation(rest)

    case parse_single_command(rest, ctx) do
      {:ok, command} ->
        {:ok, %{address1: addr1, address2: addr2, negated: negated, command: command}}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp parse_negation("!" <> rest), do: {true, String.trim_leading(rest)}
  defp parse_negation(rest), do: {false, rest}

  defp parse_addresses(cmd, ctx) do
    case cmd do
      "$" <> rest ->
        parse_address_with_optional_range(:last, String.trim_leading(rest), ctx)

      "/" <> _rest ->
        parse_regex_first_address(cmd, ctx)

      _ ->
        parse_line_number_address(cmd, ctx)
    end
  end

  defp parse_address_with_optional_range(addr1, rest, ctx) do
    if String.starts_with?(rest, ",") do
      {addr2, rest2} = parse_second_address(String.slice(rest, 1..-1//1), ctx)
      {addr1, addr2, rest2}
    else
      {addr1, nil, rest}
    end
  end

  defp parse_regex_first_address(cmd, ctx) do
    case parse_regex_address(cmd, ctx) do
      {:ok, regex, rest} ->
        parse_address_with_optional_range({:regex, regex}, String.trim_leading(rest), ctx)

      {:error, _} ->
        {nil, nil, cmd}
    end
  end

  defp parse_line_number_address(cmd, ctx) do
    case Integer.parse(cmd) do
      {n, rest} ->
        parse_address_with_optional_range({:line, n}, String.trim_leading(rest), ctx)

      :error ->
        {nil, nil, cmd}
    end
  end

  defp parse_second_address(rest, ctx) do
    rest = String.trim_leading(rest)

    case rest do
      "$" <> rest2 ->
        {:last, String.trim_leading(rest2)}

      "/" <> _rest ->
        case parse_regex_address(rest, ctx) do
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

  defp parse_regex_address(str, ctx) do
    case Regex.run(~r{^/([^/]*)/(.*)$}s, str) do
      [_, pattern, rest] ->
        case compile_regex(pattern, [], ctx) do
          {:ok, regex} -> {:ok, regex, rest}
          {:error, _} = err -> err
        end

      nil ->
        {:error, "invalid regex address"}
    end
  end

  defp parse_single_command("", _ctx), do: {:ok, :noop}
  defp parse_single_command("d", _ctx), do: {:ok, :delete}
  defp parse_single_command("p", _ctx), do: {:ok, :print}

  defp parse_single_command("s" <> rest, ctx) do
    parse_substitute_command(rest, ctx)
  end

  # a, i and c: append text after the line, insert it before, or change the
  # line to it. In the classic form, `a\` and a newline, the text starts on
  # the next line. In GNU's one-line forms the text follows on the same line:
  # after `a\` exactly as written, so leading spaces are kept, and after `a `
  # from its first non-blank character.
  defp parse_single_command(<<cmd, "\\", rest::binary>>, _ctx) when cmd in [?a, ?i, ?c] do
    {:ok, {text_command(cmd), rest |> String.replace_prefix("\n", "") |> unescape_text()}}
  end

  defp parse_single_command(<<cmd, " ", rest::binary>>, _ctx) when cmd in [?a, ?i, ?c] do
    {:ok, {text_command(cmd), rest |> String.trim_leading() |> unescape_text()}}
  end

  # y/source/dest/ - transliterate characters
  defp parse_single_command("y" <> rest, _ctx) do
    parse_translate_command(rest)
  end

  defp parse_single_command(other, _ctx) do
    {:error, "unknown command: #{String.first(other)}"}
  end

  defp parse_substitute_command(rest, ctx) do
    if String.length(rest) < 1 do
      {:error, "unterminated `s' command"}
    else
      delimiter = String.first(rest)
      rest = String.slice(rest, 1..-1//1)
      parse_substitute_parts(rest, delimiter, ctx)
    end
  end

  defp parse_substitute_parts(rest, delimiter, ctx) do
    case split_by_delimiter(rest, delimiter) do
      {:ok, pattern, replacement, flags_str} ->
        build_substitute_command(pattern, replacement, flags_str, ctx)

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp build_substitute_command(pattern, replacement, flags_str, ctx) do
    flags = parse_substitute_flags(flags_str)

    # Empty pattern means "reuse last regex"
    if pattern == "" do
      {:ok, {:substitute, :last_regex, replacement, flags}}
    else
      case compile_regex(pattern, flags, ctx) do
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
        "I" -> [:caseless | acc]
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
  @spec compile_regex(String.t(), substitute_flags(), ctx()) ::
          {:ok, Regex.t()} | {:error, String.t()}
  def compile_regex(pattern, flags, ctx) do
    # Convert BRE to ERE if not in extended mode
    # In BRE: \( \) \{ \} are special, ( ) { } are literal
    # In ERE (and PCRE): ( ) { } are special, \( \) \{ \} are literal
    converted_pattern =
      if ctx.extended do
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

    JustBash.Limit.check_regex_size!(ctx.limits, converted_pattern)

    case JustBash.TextRegex.compile(converted_pattern, regex_opts) do
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

  defp text_command(?a), do: :append
  defp text_command(?i), do: :insert
  defp text_command(?c), do: :change

  # Backslashes in a, i and c text, as GNU reads them, left to right: `\t` and
  # `\n` are a tab and a newline, and a backslash before anything else is that
  # character. A backslash at the end of a line therefore continues the text on
  # the next line, a line holding only `\` is a blank line, and `\*` is `*`.
  defp unescape_text(text), do: unescape_text(text, "")

  defp unescape_text("", acc), do: acc

  defp unescape_text("\\" <> rest, acc) do
    case String.next_grapheme(rest) do
      {"n", rest} -> unescape_text(rest, acc <> "\n")
      {"t", rest} -> unescape_text(rest, acc <> "\t")
      {char, rest} -> unescape_text(rest, acc <> char)
      nil -> acc
    end
  end

  defp unescape_text(<<c, rest::binary>>, acc), do: unescape_text(rest, acc <> <<c>>)

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

    # Lengths are in characters, as the executor maps one grapheme to one
    # grapheme: `y/“”/""/` is two characters to two.
    case parts do
      [source, dest | _] ->
        source_length = String.length(source)
        dest_length = String.length(dest)

        if source_length == dest_length do
          {:ok, {:translate, source, dest}}
        else
          {:error,
           "y command requires source and dest of same length (#{source_length} vs #{dest_length})"}
        end

      _ ->
        {:error, "unterminated `y' command"}
    end
  end
end
