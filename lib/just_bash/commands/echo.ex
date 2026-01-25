defmodule JustBash.Commands.Echo do
  @moduledoc "The `echo` command - display a line of text."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["echo"]

  @impl true
  def execute(bash, args, _stdin) do
    {flags, rest_args} = parse_flags(args)
    output = Enum.join(rest_args, " ")
    output = if flags.n, do: output, else: output <> "\n"
    output = if flags.e, do: interpret_escapes(output), else: output
    {Command.ok(output), bash}
  end

  defp parse_flags(args), do: parse_flags(args, %{n: false, e: false, E: true})

  defp parse_flags(["-n" | rest], flags),
    do: parse_flags(rest, %{flags | n: true})

  defp parse_flags(["-e" | rest], flags),
    do: parse_flags(rest, %{flags | e: true, E: false})

  defp parse_flags(["-E" | rest], flags),
    do: parse_flags(rest, %{flags | E: true, e: false})

  defp parse_flags(["-ne" | rest], flags),
    do: parse_flags(rest, %{flags | n: true, e: true, E: false})

  defp parse_flags(["-en" | rest], flags),
    do: parse_flags(rest, %{flags | n: true, e: true, E: false})

  defp parse_flags(rest, flags), do: {flags, rest}

  defp interpret_escapes(str) do
    do_interpret_escapes(str, "")
  end

  defp do_interpret_escapes("", acc), do: acc

  defp do_interpret_escapes("\\x" <> rest, acc) do
    case rest do
      <<h1, h2, tail::binary>> when h1 in ?0..?9 or h1 in ?a..?f or h1 in ?A..?F ->
        if h2 in ?0..?9 or h2 in ?a..?f or h2 in ?A..?F do
          hex = <<h1, h2>>
          char = <<String.to_integer(hex, 16)>>
          do_interpret_escapes(tail, acc <> char)
        else
          # Only one hex digit
          hex = <<h1>>
          char = <<String.to_integer(hex, 16)>>
          do_interpret_escapes(<<h2>> <> tail, acc <> char)
        end

      _ ->
        do_interpret_escapes(rest, acc <> "\\x")
    end
  end

  # Octal: \0, \0N, \0NN, \NNN (where first digit is 0-3)
  defp do_interpret_escapes("\\0" <> rest, acc) do
    {octal_chars, remaining} = take_octal_digits(rest, 2)

    if octal_chars == "" do
      # Just \0 - null byte
      do_interpret_escapes(remaining, acc <> <<0>>)
    else
      char = <<String.to_integer("0" <> octal_chars, 8)>>
      do_interpret_escapes(remaining, acc <> char)
    end
  end

  # Note: bash echo -e only interprets \0NNN octals, not \NNN
  # (Unlike $'...' ANSI-C quoting which interprets both)

  defp do_interpret_escapes("\\n" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\n")
  defp do_interpret_escapes("\\t" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\t")
  defp do_interpret_escapes("\\r" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\r")
  defp do_interpret_escapes("\\\\" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\\")
  defp do_interpret_escapes("\\a" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\a")
  defp do_interpret_escapes("\\b" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\b")
  defp do_interpret_escapes("\\e" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\e")
  defp do_interpret_escapes("\\f" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\f")
  defp do_interpret_escapes("\\v" <> rest, acc), do: do_interpret_escapes(rest, acc <> "\v")

  defp do_interpret_escapes(<<c, rest::binary>>, acc) do
    do_interpret_escapes(rest, acc <> <<c>>)
  end

  defp take_octal_digits(str, max_count) when max_count > 0 do
    case str do
      <<d, rest::binary>> when d in ?0..?7 ->
        {more, remaining} = take_octal_digits(rest, max_count - 1)
        {<<d>> <> more, remaining}

      _ ->
        {"", str}
    end
  end

  defp take_octal_digits(str, _), do: {"", str}
end
