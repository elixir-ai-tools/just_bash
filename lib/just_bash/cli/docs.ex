defmodule JustBash.CLI.Docs do
  @moduledoc """
  Renders a whole `JustBash.CLI` as a document for human or agent consumption.

  Used by `JustBash.CLI.render_docs/2`. Because docs are generated from the same spec
  that drives routing and `--help`, the documentation a host injects into an agent's
  system prompt never drifts from the CLI's actual behavior.
  """

  alias JustBash.CLI.Command
  alias JustBash.CLI.Help

  @doc """
  Render `cli` in the given `format` (`:text` or `:markdown`).
  """
  @spec render(JustBash.CLI.t(), :text | :markdown) :: String.t()
  def render(cli, :text) do
    leaves = leaf_nodes(cli.commands, [])

    [
      Help.group_help(cli, [], cli)
      | Enum.map(leaves, fn {path, node} -> Help.leaf_help(cli, path, node) end)
    ]
    |> Enum.join("\n")
  end

  def render(cli, :markdown) do
    leaves = leaf_nodes(cli.commands, [])

    header = ["# ", cli.name, "\n", optional_para(cli.doc)]
    sections = Enum.map(leaves, fn {path, node} -> markdown_command(cli, path, node) end)

    IO.iodata_to_binary([header, "\n", Enum.intersperse(sections, "\n")])
  end

  # Collect every leaf as {path, node}, depth-first, so docs list full invocation paths.
  defp leaf_nodes(commands, prefix) do
    Enum.flat_map(commands, fn cmd ->
      path = prefix ++ [cmd.name]
      if Command.group?(cmd), do: leaf_nodes(cmd.commands, path), else: [{path, cmd}]
    end)
  end

  defp markdown_command(cli, path, %Command{} = node) do
    label = Enum.join([cli.name | path], " ")
    usage = String.trim_trailing(Help.usage_line(cli, path, node))

    [
      "## ",
      label,
      "\n",
      optional_para(node.doc),
      "\n```\n",
      usage,
      "\n```\n",
      flags_table(node.flags),
      args_table(node.args),
      examples_block(node.examples)
    ]
  end

  defp examples_block([]), do: []

  defp examples_block(examples) do
    rows =
      Enum.map(examples, fn
        %{cmd: cmd, doc: nil} -> ["- `", cmd, "`\n"]
        %{cmd: cmd, doc: doc} -> ["- `", cmd, "` — ", doc, "\n"]
      end)

    ["\n**Examples:**\n\n", rows]
  end

  defp optional_para(nil), do: []
  defp optional_para(doc), do: ["\n", doc, "\n"]

  defp flags_table([]), do: []

  defp flags_table(flags) do
    rows =
      Enum.map(flags, fn {_name, spec} ->
        [
          "| `",
          flag_forms(spec),
          "` | ",
          to_string(spec[:type]),
          " | ",
          yes_no(spec[:required]),
          " | ",
          default_cell(spec),
          " | ",
          cell(spec[:doc]),
          " |\n"
        ]
      end)

    [
      "\n**Flags:**\n\n",
      "| Flag | Type | Required | Default | Description |\n",
      "|------|------|----------|---------|-------------|\n",
      rows
    ]
  end

  defp args_table([]), do: []

  defp args_table(args) do
    rows =
      Enum.map(args, fn arg ->
        ["| `", to_string(arg.name), "` | ", yes_no(arg.required), " | ", cell(arg[:doc]), " |\n"]
      end)

    [
      "\n**Arguments:**\n\n",
      "| Argument | Required | Description |\n",
      "|----------|----------|-------------|\n",
      rows
    ]
  end

  defp flag_forms(spec) do
    [spec[:short], spec[:long]] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
  end

  defp default_cell(spec) do
    case {spec[:type], spec[:default]} do
      {:boolean, _} -> ""
      {_, nil} -> ""
      {_, default} -> to_string(default)
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"

  defp cell(nil), do: ""
  defp cell(text), do: text
end
