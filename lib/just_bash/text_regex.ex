defmodule JustBash.TextRegex do
  @moduledoc """
  Compiles and runs regexes for text commands the way a UTF-8 locale does.

  GNU `sed` and `grep` in a UTF-8 locale match characters: `.` is one
  character, `[“”]` is a set of two characters, and `\\w` and `\\b` know about
  letters outside ASCII. PCRE without its Unicode options matches bytes, so
  `.` can consume one byte of a three-byte character and leave invalid UTF-8
  behind, and `caf.$` cannot match `café`. JustBash's other text commands
  (`awk length()`, `tr`) already treat text as UTF-8, so these follow suit.

  That takes two PCRE options: `:unicode` reads the pattern and subject as
  UTF-8, and `:ucp` gives `\\w`, `\\b`, `\\s` and `[[:alpha:]]` their Unicode
  meaning. Elixir's `u` modifier sets both, but an option list has to name
  both.

  A `unicode` regex refuses a subject that is not valid UTF-8 (`:re` raises
  `ArgumentError`). GNU tools treat such bytes as unmatched single bytes and
  carry on, so `for_subject/2` falls back to the same pattern compiled for
  bytes when the subject is not valid UTF-8. Binary input is therefore
  matched as before rather than crashing.
  """

  @doc """
  Compiles `pattern` with `opts`, adding `:unicode` and `:ucp` when the pattern
  itself is valid UTF-8.
  """
  @spec compile(String.t(), [atom()]) :: {:ok, Regex.t()} | {:error, term()}
  def compile(pattern, opts \\ []) do
    if String.valid?(pattern) do
      Regex.compile(pattern, [:unicode, :ucp | opts])
    else
      Regex.compile(pattern, opts)
    end
  end

  @doc "Like `compile/2`, raising on an invalid pattern."
  @spec compile!(String.t(), [atom()]) :: Regex.t()
  def compile!(pattern, opts \\ []) do
    case compile(pattern, opts) do
      {:ok, regex} -> regex
      {:error, reason} -> raise Regex.CompileError, "#{inspect(reason)}"
    end
  end

  @doc """
  The regex to run against `subject`: `regex` itself, or, when `regex` is
  compiled for UTF-8 and `subject` is not valid UTF-8, the same pattern
  compiled for bytes.
  """
  @spec for_subject(Regex.t(), binary()) :: Regex.t()
  def for_subject(%Regex{opts: opts} = regex, subject) do
    if :unicode in opts and not String.valid?(subject) do
      Regex.compile!(regex.source, opts -- [:unicode, :ucp])
    else
      regex
    end
  end

  @doc "`Regex.match?/2` through `for_subject/2`."
  @spec match?(Regex.t(), binary()) :: boolean()
  def match?(regex, subject), do: Regex.match?(for_subject(regex, subject), subject)

  @doc "`Regex.run/3` through `for_subject/2`."
  @spec run(Regex.t(), binary(), keyword()) :: [term()] | nil
  def run(regex, subject, opts \\ []), do: Regex.run(for_subject(regex, subject), subject, opts)

  @doc "`Regex.scan/3` through `for_subject/2`."
  @spec scan(Regex.t(), binary(), keyword()) :: [[term()]]
  def scan(regex, subject, opts \\ []),
    do: Regex.scan(for_subject(regex, subject), subject, opts)

  @doc """
  Translates a POSIX basic regular expression, as GNU `sed` and `grep` read
  one, into PCRE.

  The two languages swap the meaning of several characters. In a BRE `?`, `+`,
  `|`, `{`, `}`, `(` and `)` are ordinary characters, and the operators are
  spelled `\\?`, `\\+`, `\\|`, `\\{...\\}` and `\\(...\\)`. PCRE reads the bare
  characters as operators and the escaped ones as literals, and both spellings
  compile, so a BRE passed through unchanged matches something else without an
  error: `in? Yes` stops matching the text `in? Yes`.

  It reads the pattern once, left to right, taking each backslash with the
  character it escapes, so an escaped character is never re-read as syntax:

  - `^` is an anchor at the start of the pattern, a group or an alternative,
    and `$` at the end of one; elsewhere each is literal (`costs $5`).
  - `*` with nothing to repeat (at the start, or after `^`) is literal.
  - A bracket expression is copied as a set with its backslashes literal, as
    POSIX has them, so `[\\.]` is a backslash or a dot.
  - `\\<` and `\\>` are GNU's word start and end.

  Options:

  - `:delimiter` - the delimiter of the `sed` command the pattern came from;
    escaped, it is that character, even in a bracket expression (`s|a\\|b||`
    removes `a|b`)
  - `:bracket_escapes` - `true` for `sed`, where `\\n` and `\\t` in a bracket
    expression are a newline and a tab
  """
  @spec bre_to_pcre(String.t(), keyword()) :: String.t()
  def bre_to_pcre(pattern, opts \\ []) do
    ctx = %{
      delimiter: Keyword.get(opts, :delimiter),
      bracket_escapes: Keyword.get(opts, :bracket_escapes, false)
    }

    pattern |> bre(true, ctx, []) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # `start` is true where `^` anchors and `*` has nothing to repeat.
  defp bre(<<>>, _start, _ctx, acc), do: acc

  defp bre("\\" <> rest, start, ctx, acc) do
    case String.next_grapheme(rest) do
      nil ->
        ["\\\\" | acc]

      {char, rest} when char == ctx.delimiter ->
        bre(rest, false, ctx, [Regex.escape(char) | acc])

      {"(", rest} ->
        bre(rest, true, ctx, ["(" | acc])

      {"|", rest} ->
        bre(rest, true, ctx, ["|" | acc])

      {char, rest} when char in [")", "{", "}", "?", "+"] ->
        bre(rest, false, ctx, [char | acc])

      {"<", rest} ->
        bre(rest, false, ctx, ["\\b(?=\\w)" | acc])

      {">", rest} ->
        bre(rest, false, ctx, ["\\b(?<=\\w)" | acc])

      {"`", rest} ->
        bre(rest, start, ctx, ["\\A" | acc])

      {"'", rest} ->
        bre(rest, false, ctx, ["\\z" | acc])

      {char, rest} ->
        bre(rest, false, ctx, ["\\" <> char | acc])
    end
  end

  defp bre("[" <> rest, _start, ctx, acc) do
    case bracket(rest, ctx) do
      {:ok, set, rest} -> bre(rest, false, ctx, [set | acc])
      :error -> bre(rest, false, ctx, ["\\[" | acc])
    end
  end

  defp bre("^" <> rest, true, ctx, acc), do: bre(rest, true, ctx, ["^" | acc])
  defp bre("^" <> rest, false, ctx, acc), do: bre(rest, false, ctx, ["\\^" | acc])

  defp bre("$" <> rest, _start, ctx, acc) do
    anchor? = rest == "" or String.starts_with?(rest, ["\\)", "\\|"])
    bre(rest, false, ctx, [if(anchor?, do: "$", else: "\\$") | acc])
  end

  defp bre("*" <> rest, true, ctx, acc), do: bre(rest, false, ctx, ["\\*" | acc])

  defp bre(<<c, rest::binary>>, _start, ctx, acc) when c in ~c"(){}|?+",
    do: bre(rest, false, ctx, ["\\" <> <<c>> | acc])

  defp bre(str, _start, ctx, acc) do
    {char, rest} = String.next_grapheme(str)
    bre(rest, false, ctx, [char | acc])
  end

  # A bracket expression after its `[`: an optional `^`, a `]` taken literally
  # when it comes first, and `[:class:]`, `[=x=]` and `[.x.]` as units, up to
  # the closing `]`. With no closing `]`, the `[` is literal.
  defp bracket(str, ctx) do
    {negate, str} =
      case str do
        "^" <> rest -> {"^", rest}
        rest -> {"", rest}
      end

    {first, str} =
      case str do
        "]" <> rest -> {"\\]", rest}
        rest -> {"", rest}
      end

    case bracket_body(str, ctx, [first]) do
      {:ok, body, rest} -> {:ok, ["[", negate, body, "]"], rest}
      :error -> :error
    end
  end

  defp bracket_body(<<>>, _ctx, _acc), do: :error
  defp bracket_body("]" <> rest, _ctx, acc), do: {:ok, Enum.reverse(acc), rest}

  defp bracket_body(<<"[", kind, rest::binary>> = str, ctx, acc) when kind in ~c":=." do
    closing = <<kind, "]">>

    case String.split(rest, closing, parts: 2) do
      [name, rest] -> bracket_body(rest, ctx, ["[" <> <<kind>> <> name <> closing | acc])
      [_] -> bracket_literal(str, ctx, acc)
    end
  end

  defp bracket_body("\\" <> rest, ctx, acc) do
    case String.next_grapheme(rest) do
      {char, rest} when char == ctx.delimiter ->
        bracket_body(rest, ctx, [Regex.escape(char) | acc])

      {char, rest} when ctx.bracket_escapes and char in ["n", "t"] ->
        bracket_body(rest, ctx, ["\\" <> char | acc])

      {"\\", rest} when ctx.bracket_escapes ->
        bracket_body(rest, ctx, ["\\\\" | acc])

      _ ->
        bracket_body(rest, ctx, ["\\\\" | acc])
    end
  end

  defp bracket_body(str, ctx, acc), do: bracket_literal(str, ctx, acc)

  # One character of a set, escaped where PCRE would read it as syntax inside
  # a class: `[` (which could start `[:`) and a backslash.
  defp bracket_literal(str, ctx, acc) do
    {char, rest} = String.next_grapheme(str)
    char = if char in ["[", "\\"], do: "\\" <> char, else: char
    bracket_body(rest, ctx, [char | acc])
  end
end
