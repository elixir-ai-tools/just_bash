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
end
