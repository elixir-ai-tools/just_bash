defmodule JustBash.Commands.Tr do
  @moduledoc "The `tr` command - translate or delete characters."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["tr"]

  @impl true
  def execute(bash, args, stdin) do
    case args do
      ["-d", chars] ->
        output = String.replace(stdin, ~r/[#{Regex.escape(chars)}]/, "")
        {Command.ok(output), bash}

      [set1, set2] ->
        output = translate(stdin, set1, set2)
        {Command.ok(output), bash}

      _ ->
        {Command.error("tr: missing operand\n"), bash}
    end
  end

  defp translate(input, set1, set2) do
    set1_expanded = expand_set(set1)
    set2_expanded = expand_set(set2)

    set2_padded =
      if String.length(set2_expanded) < String.length(set1_expanded) do
        last_char = String.last(set2_expanded) || ""

        padding =
          String.duplicate(last_char, String.length(set1_expanded) - String.length(set2_expanded))

        set2_expanded <> padding
      else
        set2_expanded
      end

    mapping =
      Enum.zip(String.graphemes(set1_expanded), String.graphemes(set2_padded))
      |> Map.new()

    input
    |> String.graphemes()
    |> Enum.map(fn char -> Map.get(mapping, char, char) end)
    |> Enum.join()
  end

  defp expand_set(set) do
    Regex.replace(~r/(.)-(.)/u, set, fn _, from, to ->
      from_cp = String.to_charlist(from) |> hd()
      to_cp = String.to_charlist(to) |> hd()

      if from_cp <= to_cp do
        Enum.map(from_cp..to_cp, &<<&1::utf8>>) |> Enum.join()
      else
        from <> "-" <> to
      end
    end)
  end
end
