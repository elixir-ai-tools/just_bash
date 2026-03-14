defmodule JustBash.Commands.Tr do
  @moduledoc "The `tr` command - translate or delete characters."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["tr"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:ok, opts} ->
        output = run(stdin, opts)
        {Command.ok(output), bash}

      {:error, msg} ->
        {Command.error(msg), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{delete: false, squeeze: false, complement: false, sets: []})
  end

  defp parse_args([], %{sets: []} = _opts) do
    {:error, "tr: missing operand\n"}
  end

  defp parse_args([], opts) do
    {:ok, %{opts | sets: Enum.reverse(opts.sets)}}
  end

  defp parse_args(["-d" | rest], opts), do: parse_args(rest, %{opts | delete: true})
  defp parse_args(["-s" | rest], opts), do: parse_args(rest, %{opts | squeeze: true})
  defp parse_args(["-c" | rest], opts), do: parse_args(rest, %{opts | complement: true})
  defp parse_args(["-C" | rest], opts), do: parse_args(rest, %{opts | complement: true})

  # Combined flags like -ds, -cs, -cd, etc.
  defp parse_args(["-" <> flags | rest], opts) when byte_size(flags) > 1 do
    opts =
      flags
      |> String.graphemes()
      |> Enum.reduce(opts, fn
        "d", acc -> %{acc | delete: true}
        "s", acc -> %{acc | squeeze: true}
        "c", acc -> %{acc | complement: true}
        "C", acc -> %{acc | complement: true}
        _, acc -> acc
      end)

    parse_args(rest, opts)
  end

  defp parse_args([set | rest], opts) do
    parse_args(rest, %{opts | sets: [set | opts.sets]})
  end

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
