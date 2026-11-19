defmodule JustBash.Commands.Sed.Parser do
  @moduledoc """
  Parser for SED scripts.

  Parses SED script strings into a program the Executor runs: a tuple of
  commands, indexed from 0, in which `{` knows the index of its `}` and every
  branch knows the index it jumps to.
  """

  alias JustBash.TextRegex

  @type address ::
          nil
          | :last
          | {:line, non_neg_integer()}
          | {:step, non_neg_integer(), non_neg_integer()}
          | {:regex, Regex.t() | :last}
  @type range_end :: address() | {:plus, non_neg_integer()} | {:multiple, non_neg_integer()}
  @type substitute_flags :: [:global | :caseless | :print | {:nth, pos_integer()}]
  @type command ::
          :noop
          | :delete
          | :print
          | {:substitute, Regex.t() | :last_regex, String.t(), substitute_flags()}
          | {:append, String.t()}
          | {:insert, String.t()}
          | {:change, String.t()}
          | {:read_file, String.t()}
          | {:translate, String.t(), String.t()}
          | {:block, non_neg_integer()}
          | :block_end
          | {:label, String.t()}
          | {:branch, non_neg_integer() | :end}
          | {:branch_if_substituted, non_neg_integer() | :end}
          | {:branch_unless_substituted, non_neg_integer() | :end}
          | :next
          | :append_next
          | :print_first_line
          | :delete_first_line
          | :hold
          | :hold_append
          | :get
          | :get_append
          | :exchange
          | :line_number
          | :zap
          | :quit
          | :quit_silently
  @type sed_command :: %{
          address1: address(),
          address2: range_end(),
          negated: boolean(),
          command: command()
        }
  @type program :: {sed_command()}

  # Parser context threaded through all functions
  @typep ctx :: %{extended: boolean(), limits: JustBash.Limit.t() | nil}

  @doc """
  Parse SED scripts into a program.

  Returns `{:ok, program}` on success or `{:error, message}` on failure. A
  branch to a label the script does not define is `{:panic, message}`: GNU
  reports it after parsing, as a panic, with exit status 4.
  """
  @spec parse([String.t()], boolean(), JustBash.Limit.t() | nil) ::
          {:ok, tuple()} | {:error, String.t()} | {:panic, String.t()}
  def parse(scripts, extended, limits \\ nil)
  def parse([], _extended, _limits), do: {:error, "no script specified"}

  def parse(scripts, extended, limits) do
    ctx = %{extended: extended, limits: limits}

    # GNU joins the scripts of several -e options with newlines before parsing
    # them, so `-e '1a\' -e 'text'` is one append whose text is on the next
    # line, as if the script had been written on two lines.
    commands = scripts |> Enum.join("\n") |> parse_script(ctx)

    case Enum.find(commands, &match?({:error, _}, &1)) do
      nil -> link(commands)
      error -> error
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
  # named "c/". `{` and `}` are commands of their own, so `1{/^$/d}` is three.
  defp split_commands("", acc), do: Enum.reverse(acc)

  defp split_commands(script, acc) do
    {address, rest} = take_address(script, "")
    {body, rest} = take_body(rest)
    split_commands(rest, [address <> body | acc])
  end

  # Line numbers, `$`, steps (`1~2`), ranges (`/a/,+2`, `5,~4`), negation and
  # regex addresses (`/re/`, `\%re%`, either with GNU's `I` flag) ahead of the
  # command letter.
  defp take_address(<<c, rest::binary>>, acc) when c in ~c"0123456789$,!~+ \t" do
    take_address(rest, acc <> <<c>>)
  end

  defp take_address("/" <> rest, acc) do
    {regex, rest} = take_delimited(rest, "/", "")
    take_address_flag(rest, acc <> "/" <> regex)
  end

  defp take_address("\\" <> rest, acc) do
    case String.next_grapheme(rest) do
      {delimiter, rest} when delimiter not in ["\n", "\\"] ->
        {regex, rest} = take_delimited(rest, delimiter, "")
        take_address_flag(rest, acc <> "\\" <> delimiter <> regex)

      _ ->
        {acc, "\\" <> rest}
    end
  end

  defp take_address(rest, acc), do: {acc, rest}

  defp take_address_flag("I" <> rest, acc), do: take_address(rest, acc <> "I")
  defp take_address_flag(rest, acc), do: take_address(rest, acc)

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

  # The text of a, i and c, and the file name of r, run to the end of the line.
  defp take_body(<<cmd, rest::binary>>) when cmd in [?a, ?i, ?c, ?r] do
    take_text(rest, <<cmd>>)
  end

  defp take_body("{" <> rest), do: {"{", rest}
  defp take_body("}" <> rest), do: {"}", skip_separator(rest)}

  # A comment runs to the end of the line.
  defp take_body("#" <> rest) do
    case String.split(rest, "\n", parts: 2) do
      [_comment, rest] -> {"", rest}
      [_comment] -> {"", ""}
    end
  end

  defp take_body(rest), do: take_to_separator(rest, "")

  # After `}`, a `;` is allowed and means nothing: `1{p};p`.
  defp skip_separator(rest) do
    case String.trim_leading(rest, " ") do
      ";" <> rest -> rest
      _ -> rest
    end
  end

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

  # Up to a `;` or newline, which is consumed and not returned, or up to a
  # `}`, which closes a block and is the next command.
  defp take_to_separator("", acc), do: {acc, ""}
  defp take_to_separator(";" <> rest, acc), do: {acc, rest}
  defp take_to_separator("\n" <> rest, acc), do: {acc, rest}
  defp take_to_separator("}" <> _ = rest, acc), do: {acc, rest}

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
    with {:ok, addr1, addr2, rest} <- parse_addresses(cmd, ctx),
         {negated, rest} = parse_negation(rest),
         {:ok, command} <- parse_single_command(rest, addr1, ctx) do
      %{address1: addr1, address2: addr2, negated: negated, command: command}
    end
  end

  defp parse_negation("!" <> rest), do: {true, String.trim_leading(rest)}
  defp parse_negation(rest), do: {false, rest}

  defp parse_addresses(cmd, ctx) do
    with {:ok, addr1, rest} <- parse_first_address(cmd, ctx),
         {:ok, addr2, rest} <- parse_range_end(addr1, String.trim_leading(rest), ctx) do
      check_line_zero(addr1, addr2, rest)
    end
  end

  # Line 0 is an address only as the start of `0,/re/`, a range that can end
  # on line 1.
  defp check_line_zero({:line, 0}, {:regex, _} = addr2, rest), do: {:ok, {:line, 0}, addr2, rest}
  defp check_line_zero({:line, 0}, _addr2, _rest), do: {:error, "invalid usage of line address 0"}
  defp check_line_zero(addr1, addr2, rest), do: {:ok, addr1, addr2, rest}

  defp parse_first_address("$" <> rest, _ctx), do: {:ok, :last, rest}

  defp parse_first_address(<<c, _::binary>> = cmd, ctx) when c in [?/, ?\\],
    do: parse_regex_address(cmd, ctx)

  defp parse_first_address(cmd, _ctx) do
    case Integer.parse(cmd) do
      {first, "~" <> rest} ->
        case Integer.parse(rest) do
          {step, rest} when step >= 0 -> {:ok, {:step, first, step}, rest}
          _ -> {:error, "expected number after ~"}
        end

      {n, rest} when n >= 0 ->
        {:ok, {:line, n}, rest}

      _ ->
        {:ok, nil, cmd}
    end
  end

  defp parse_range_end(nil, rest, _ctx), do: {:ok, nil, rest}

  defp parse_range_end(_addr1, "," <> rest, ctx) do
    rest = String.trim_leading(rest)

    case rest do
      "$" <> rest ->
        {:ok, :last, rest}

      <<c, _::binary>> when c in [?/, ?\\] ->
        parse_regex_address(rest, ctx)

      <<c, rest::binary>> when c in [?+, ?~] ->
        case Integer.parse(rest) do
          {n, rest} when n >= 0 -> {:ok, if(c == ?+, do: {:plus, n}, else: {:multiple, n}), rest}
          _ -> {:error, "expected number after #{<<c>>}"}
        end

      _ ->
        case Integer.parse(rest) do
          {n, rest} when n >= 0 -> {:ok, {:line, n}, rest}
          _ -> {:error, "unexpected `,'"}
        end
    end
  end

  defp parse_range_end(_addr1, rest, _ctx), do: {:ok, nil, rest}

  # `/re/` or `\cREc`, optionally followed by `I` for a case-insensitive
  # match. An empty regex, `//`, is the last regex used.
  defp parse_regex_address("/" <> rest, ctx), do: parse_regex_address_body(rest, "/", ctx)

  defp parse_regex_address("\\" <> rest, ctx) do
    case String.next_grapheme(rest) do
      {delimiter, rest} when delimiter not in ["\n", "\\"] ->
        parse_regex_address_body(rest, delimiter, ctx)

      _ ->
        {:error, "unexpected `\\'"}
    end
  end

  defp parse_regex_address_body(rest, delimiter, ctx) do
    {body, rest} = take_delimited(rest, delimiter, "")

    if String.ends_with?(body, delimiter) do
      pattern = String.slice(body, 0..-2//1)

      {flags, rest} =
        if String.starts_with?(rest, "I"),
          do: {[:caseless], String.slice(rest, 1..-1//1)},
          else: {[], rest}

      if pattern == "" do
        {:ok, {:regex, :last}, rest}
      else
        with {:ok, regex} <- compile_regex(pattern, flags, delimiter, ctx),
             do: {:ok, {:regex, regex}, rest}
      end
    else
      {:error, "unterminated address regex"}
    end
  end

  defp parse_single_command("", nil, _ctx), do: {:ok, :noop}
  defp parse_single_command("", _addr, _ctx), do: {:error, "missing command"}
  defp parse_single_command("d", _addr, _ctx), do: {:ok, :delete}
  defp parse_single_command("D", _addr, _ctx), do: {:ok, :delete_first_line}
  defp parse_single_command("p", _addr, _ctx), do: {:ok, :print}
  defp parse_single_command("P", _addr, _ctx), do: {:ok, :print_first_line}
  defp parse_single_command("n", _addr, _ctx), do: {:ok, :next}
  defp parse_single_command("N", _addr, _ctx), do: {:ok, :append_next}
  defp parse_single_command("h", _addr, _ctx), do: {:ok, :hold}
  defp parse_single_command("H", _addr, _ctx), do: {:ok, :hold_append}
  defp parse_single_command("g", _addr, _ctx), do: {:ok, :get}
  defp parse_single_command("G", _addr, _ctx), do: {:ok, :get_append}
  defp parse_single_command("x", _addr, _ctx), do: {:ok, :exchange}
  defp parse_single_command("=", _addr, _ctx), do: {:ok, :line_number}
  defp parse_single_command("z", _addr, _ctx), do: {:ok, :zap}
  defp parse_single_command("q", _addr, _ctx), do: {:ok, :quit}
  defp parse_single_command("Q", _addr, _ctx), do: {:ok, :quit_silently}
  defp parse_single_command("{", _addr, _ctx), do: {:ok, {:block, nil}}
  defp parse_single_command("}", nil, _ctx), do: {:ok, :block_end}
  defp parse_single_command("}", _addr, _ctx), do: {:error, "} doesn't want any addresses"}

  defp parse_single_command(":" <> label, nil, _ctx) do
    case String.trim(label) do
      "" -> {:error, "\":\" lacks a label"}
      label -> {:ok, {:label, label}}
    end
  end

  defp parse_single_command(":" <> _label, _addr, _ctx),
    do: {:error, ": doesn't want any addresses"}

  # `b`, `t` and `T` with no label jump to the end of the script. The label
  # may follow the letter directly, as in `:a;N;$!ba`.
  defp parse_single_command(<<cmd, rest::binary>>, _addr, _ctx) when cmd in [?b, ?t, ?T] do
    label = String.trim(rest)
    {:ok, {branch_command(cmd), if(label == "", do: :end, else: label)}}
  end

  defp parse_single_command("s" <> rest, _addr, ctx) do
    parse_substitute_command(rest, ctx)
  end

  # a, i and c: append text after the line, insert it before, or change the
  # line to it. In the classic form, `a\` and a newline, the text starts on
  # the next line. In GNU's one-line forms the text follows on the same line:
  # after `a\` exactly as written, so leading spaces are kept, and after `a`
  # from its first non-blank character, with or without a space before it
  # (`24a- item`).
  defp parse_single_command(<<cmd, "\\", rest::binary>>, _addr, _ctx) when cmd in [?a, ?i, ?c] do
    {:ok, {text_command(cmd), rest |> String.replace_prefix("\n", "") |> unescape_text()}}
  end

  defp parse_single_command(<<cmd>>, _addr, _ctx) when cmd in [?a, ?i, ?c],
    do: {:error, "expected \\ after `a', `c' or `i'"}

  defp parse_single_command(<<cmd, rest::binary>>, _addr, _ctx) when cmd in [?a, ?i, ?c] do
    {:ok, {text_command(cmd), rest |> String.trim_leading() |> unescape_text()}}
  end

  # r: queue a file's contents to be printed at the end of the cycle.
  defp parse_single_command("r" <> rest, _addr, _ctx) do
    case String.trim_leading(rest) do
      "" -> {:error, "missing filename in r/R/w/W commands"}
      file -> {:ok, {:read_file, file}}
    end
  end

  # y/source/dest/ - transliterate characters
  defp parse_single_command("y" <> rest, _addr, _ctx) do
    parse_translate_command(rest)
  end

  defp parse_single_command(other, _addr, _ctx) do
    {:error, "unknown command: #{String.first(other)}"}
  end

  defp branch_command(?b), do: :branch
  defp branch_command(?t), do: :branch_if_substituted
  defp branch_command(?T), do: :branch_unless_substituted

  # Pairs each `{` with its `}` and resolves every branch to the index of its
  # label, turning the command list into the program the executor runs.
  defp link(commands) do
    indexed = Enum.with_index(commands)

    labels =
      for {%{command: {:label, label}}, index} <- indexed, into: %{}, do: {label, index}

    with {:ok, blocks} <- pair_blocks(indexed, [], %{}) do
      indexed
      |> Enum.reduce_while({:ok, []}, fn {cmd, index}, {:ok, acc} ->
        case resolve(cmd, index, blocks, labels) do
          {:ok, cmd} -> {:cont, {:ok, [cmd | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, acc |> Enum.reverse() |> List.to_tuple()}
        error -> error
      end
    end
  end

  defp pair_blocks([], [], blocks), do: {:ok, blocks}
  defp pair_blocks([], [_open | _], _blocks), do: {:error, "unmatched `{'"}

  defp pair_blocks([{%{command: {:block, _}}, index} | rest], open, blocks),
    do: pair_blocks(rest, [index | open], blocks)

  defp pair_blocks([{%{command: :block_end}, _index} | _rest], [], _blocks),
    do: {:error, "unexpected `}'"}

  defp pair_blocks([{%{command: :block_end}, index} | rest], [start | open], blocks),
    do: pair_blocks(rest, open, Map.put(blocks, start, index))

  defp pair_blocks([_ | rest], open, blocks), do: pair_blocks(rest, open, blocks)

  defp resolve(%{command: {:block, _}} = cmd, index, blocks, _labels),
    do: {:ok, %{cmd | command: {:block, Map.fetch!(blocks, index)}}}

  defp resolve(%{command: {branch, label}} = cmd, _index, _blocks, labels)
       when branch in [:branch, :branch_if_substituted, :branch_unless_substituted] and
              label != :end do
    case Map.fetch(labels, label) do
      {:ok, target} -> {:ok, %{cmd | command: {branch, target}}}
      :error -> {:panic, "can't find label for jump to `#{label}'"}
    end
  end

  defp resolve(cmd, _index, _blocks, _labels), do: {:ok, cmd}

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
        build_substitute_command(pattern, replacement, flags_str, delimiter, ctx)

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp build_substitute_command(pattern, replacement, flags_str, delimiter, ctx) do
    flags = parse_substitute_flags(flags_str)

    # Empty pattern means "reuse last regex"
    if pattern == "" do
      {:ok, {:substitute, :last_regex, replacement, flags}}
    else
      case compile_regex(pattern, flags, delimiter, ctx) do
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

  A basic regular expression (no `-E`) is translated to PCRE by
  `JustBash.TextRegex.bre_to_pcre/2`, which also reads an escaped
  `delimiter` as that character. In an extended one PCRE already reads an
  escaped delimiter as the character, so it is compiled as written.
  """
  @spec compile_regex(String.t(), substitute_flags(), String.t(), ctx()) ::
          {:ok, Regex.t()} | {:error, String.t()}
  def compile_regex(pattern, flags, delimiter, ctx) do
    converted_pattern =
      if ctx.extended do
        pattern
      else
        TextRegex.bre_to_pcre(pattern, delimiter: delimiter, bracket_escapes: true)
      end

    # A pattern space can hold several lines once `N` or `G` has joined
    # them. In GNU sed `$` then matches only at its very end, and `.` matches
    # a newline; PCRE's `$` also matches before a final newline, so `^$` would
    # match "\n".
    regex_opts =
      Enum.filter(
        [
          :dollar_endonly,
          :dotall,
          if(:caseless in flags, do: :caseless)
        ],
        & &1
      )

    JustBash.Limit.check_regex_size!(ctx.limits, converted_pattern)

    case TextRegex.compile(converted_pattern, regex_opts) do
      {:ok, regex} -> {:ok, regex}
      {:error, {msg, _}} -> {:error, "invalid regex: #{msg}"}
    end
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
