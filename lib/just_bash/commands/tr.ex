defmodule JustBash.Commands.Tr do
  @moduledoc "The `tr` command - translate or delete characters."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FlagParser

  @try_help "Try 'tr --help' for more information.\n"

  # `tr` keeps its own reducer because a set may look like a flag, but the flags
  # it accepts are still declared once, so `tr --help` answers from them.
  @flag_spec %{
    boolean: [:c, :d, :s],
    value: [],
    aliases: %{"C" => :c},
    defaults: %{c: false, d: false, s: false},
    usage: "tr [OPTION]... SET1 [SET2]"
  }

  @impl true
  def names, do: ["tr"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:ok, opts} ->
        output = run(stdin, opts)
        {Command.ok(output), bash}

      :help ->
        {Command.ok(FlagParser.help("tr", @flag_spec)), bash}

      {:error, msg} ->
        {Command.error(msg), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{delete: false, squeeze: false, complement: false, sets: []})
  end

  defp parse_args([], %{sets: []} = _opts) do
    {:error, "tr: missing operand\n" <> @try_help}
  end

  # One set is enough to delete or squeeze, but translating needs somewhere to
  # translate to. Falling through to `run/2`'s catch-all answered with empty
  # output at exit 0 - the failure this command's flag handling exists to stop.
  defp parse_args([], %{delete: false, squeeze: false, sets: [set]}) do
    {:error,
     "tr: missing operand after '#{set}'\n" <>
       "Two strings must be given when translating.\n" <> @try_help}
  end

  defp parse_args([], opts) do
    {:ok, %{opts | sets: Enum.reverse(opts.sets)}}
  end

  defp parse_args(["--help" | _rest], _opts), do: :help

  # Everything after `--` is a character set, even when it is dash-shaped.
  defp parse_args(["--" | rest], opts) do
    parse_args([], %{opts | sets: Enum.reverse(rest) ++ opts.sets})
  end

  # Combined flags like -ds, -cs, -cd, and single flags like -d. A character
  # the reducer does not know is an error: dropping it silently made
  # `tr -dX b` delete `b` and report success, and a lone unknown flag such as
  # `-x` used to fall through to the clause below and become a character set.
  defp parse_args(["-" <> flags | rest], opts) when flags != "" do
    case reduce_flags(flags, opts) do
      {:ok, opts} -> parse_args(rest, opts)
      {:error, _reason} = error -> error
    end
  end

  defp parse_args([set | rest], opts) do
    parse_args(rest, %{opts | sets: [set | opts.sets]})
  end

  defp reduce_flags("-" <> _ = long_flag, _opts) do
    {:error, unknown_flag("-" <> long_flag)}
  end

  defp reduce_flags(flags, opts) do
    flags
    |> String.graphemes()
    |> Enum.reduce_while({:ok, opts}, fn char, {:ok, acc} -> apply_flag(char, acc) end)
  end

  defp apply_flag("d", opts), do: {:cont, {:ok, %{opts | delete: true}}}
  defp apply_flag("s", opts), do: {:cont, {:ok, %{opts | squeeze: true}}}

  defp apply_flag(char, opts) when char in ["c", "C"],
    do: {:cont, {:ok, %{opts | complement: true}}}

  defp apply_flag(char, _opts), do: {:halt, {:error, unknown_flag(char)}}

  defp unknown_flag(flag), do: FlagParser.format_error("tr", {:unknown_flag, flag}, @try_help)

  defp run(input, %{delete: true, squeeze: false, sets: [set1]}) do
    chars = expand_set(set1) |> MapSet.new(&<<&1::utf8>>)
    delete_chars(input, chars)
  end

  defp run(input, %{delete: true, squeeze: true, sets: [set1, set2]}) do
    del_chars = expand_set(set1) |> MapSet.new(&<<&1::utf8>>)
    sq_chars = expand_set(set2) |> MapSet.new(&<<&1::utf8>>)

    input
    |> delete_chars(del_chars)
    |> squeeze(sq_chars)
  end

  defp run(input, %{squeeze: true, complement: false, sets: [set1]}) do
    chars = expand_set(set1) |> MapSet.new(&<<&1::utf8>>)
    squeeze(input, chars)
  end

  defp run(input, %{squeeze: true, complement: true, sets: [set1, set2]}) do
    set1_expanded = expand_set(set1)
    set2_expanded = expand_set(set2)
    set1_chars = MapSet.new(set1_expanded, &<<&1::utf8>>)

    mapping = build_complement_mapping(set1_chars, set2_expanded)

    input
    |> String.graphemes()
    |> Enum.map(fn char ->
      if MapSet.member?(set1_chars, char), do: char, else: Map.get(mapping, :replacement)
    end)
    |> squeeze_graphemes(MapSet.new([Map.get(mapping, :replacement)]))
    |> IO.iodata_to_binary()
  end

  defp run(input, %{complement: true, sets: [set1, set2]}) do
    set1_expanded = expand_set(set1)
    set2_expanded = expand_set(set2)
    set1_chars = MapSet.new(set1_expanded, &<<&1::utf8>>)

    mapping = build_complement_mapping(set1_chars, set2_expanded)

    input
    |> String.graphemes()
    |> Enum.map_join("", fn char ->
      if MapSet.member?(set1_chars, char), do: char, else: Map.get(mapping, :replacement)
    end)
  end

  defp run(input, %{squeeze: true, sets: [set1, set2]}) do
    set2_chars = expand_set(set2) |> MapSet.new(&<<&1::utf8>>)

    input
    |> translate(set1, set2)
    |> squeeze(set2_chars)
  end

  defp run(input, %{sets: [set1, set2]}) do
    translate(input, set1, set2)
  end

  defp run(_input, _opts) do
    ""
  end

  defp delete_chars(input, chars) do
    input
    |> String.graphemes()
    |> Enum.reject(fn char -> MapSet.member?(chars, char) end)
    |> IO.iodata_to_binary()
  end

  defp squeeze(input, chars) do
    input
    |> String.graphemes()
    |> squeeze_graphemes(chars)
    |> IO.iodata_to_binary()
  end

  defp squeeze_graphemes(graphemes, chars) do
    squeeze_graphemes(graphemes, chars, nil, [])
  end

  defp squeeze_graphemes([], _chars, _prev, acc), do: Enum.reverse(acc)

  defp squeeze_graphemes([char | rest], chars, prev, acc) do
    if char == prev and MapSet.member?(chars, char) do
      squeeze_graphemes(rest, chars, prev, acc)
    else
      squeeze_graphemes(rest, chars, char, [char | acc])
    end
  end

  defp build_complement_mapping(set1_chars, set2_expanded) do
    # For complement mode, the replacement is the last char of set2
    replacement =
      case set2_expanded do
        [] -> ""
        list -> <<List.last(list)::utf8>>
      end

    %{replacement: replacement, set1: set1_chars}
  end

  defp translate(input, set1, set2) do
    set1_expanded = expand_set(set1)
    set2_expanded = expand_set(set2)

    set2_padded =
      if length(set2_expanded) < length(set1_expanded) do
        last_char = List.last(set2_expanded) || 0

        padding =
          List.duplicate(last_char, length(set1_expanded) - length(set2_expanded))

        set2_expanded ++ padding
      else
        set2_expanded
      end

    mapping =
      Enum.zip(set1_expanded, set2_padded)
      |> Map.new(fn {from, to} -> {<<from::utf8>>, <<to::utf8>>} end)

    input
    |> String.graphemes()
    |> Enum.map_join("", fn char -> Map.get(mapping, char, char) end)
  end

  @doc false
  def expand_set(set) do
    set
    |> expand_posix_classes()
    |> expand_escapes()
    |> expand_ranges()
    |> String.to_charlist()
  end

  @posix_classes %{
    "[:upper:]" => "A-Z",
    "[:lower:]" => "a-z",
    "[:alpha:]" => "A-Za-z",
    "[:digit:]" => "0-9",
    "[:alnum:]" => "A-Za-z0-9",
    "[:space:]" => " \\t\\n\\r",
    "[:blank:]" => " \\t",
    "[:punct:]" => "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
    "[:xdigit:]" => "0-9A-Fa-f",
    "[:print:]" => " -~",
    "[:graph:]" => "!-~",
    "[:cntrl:]" => "\\x00-\\x1f\\x7f"
  }

  defp expand_posix_classes(set) do
    Enum.reduce(@posix_classes, set, fn {class, expansion}, acc ->
      String.replace(acc, class, expansion)
    end)
  end

  # Interpret backslash escape sequences like \n, \t, \\
  defp expand_escapes(set) do
    set
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\\", "\\")
  end

  defp expand_ranges(set) do
    Regex.replace(~r/(.)-(.)/u, set, fn _, from, to ->
      from_cp = String.to_charlist(from) |> hd()
      to_cp = String.to_charlist(to) |> hd()

      if from_cp <= to_cp do
        Enum.map_join(from_cp..to_cp, "", &<<&1::utf8>>)
      else
        from <> "-" <> to
      end
    end)
  end
end
