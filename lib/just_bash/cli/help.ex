defmodule JustBash.CLI.Help do
  @moduledoc """
  Renders `--help` text, usage lines, and usage errors for a `JustBash.CLI`.

  All output is derived purely from the CLI's declarative spec, so help can never drift
  from runtime behavior. Output format is consistent across every CLI built on the
  feature — which is the point: agents recover from a typo or a missing flag in one turn
  because the error always carries a usage line and (for unknown commands) a suggestion.
  """

  alias JustBash.CLI.Command

  @doc """
  Full `--help` text for a group node (the CLI root or a `%Command{}` group).

  `path` is the subcommand path to the group (`[]` for the root).
  """
  @spec group_help(JustBash.CLI.t(), [String.t()], struct()) :: String.t()
  def group_help(cli, path, group) do
    label = label(cli, path)
    children = group.commands

    [
      title(label, group.doc),
      "Usage: #{label} <command> [args]\n",
      commands_section(children),
      "Run '#{label} <command> --help' for more information on a command.\n"
    ]
    |> compact_join()
  end

  @doc """
  Full `--help` text for a leaf command.
  """
  @spec leaf_help(JustBash.CLI.t(), [String.t()], Command.t()) :: String.t()
  def leaf_help(cli, path, %Command{} = leaf) do
    [
      title(label(cli, path), leaf.doc),
      usage_line(cli, path, leaf),
      args_section(leaf.args),
      options_section(leaf.flags),
      examples_section(leaf.examples)
    ]
    |> compact_join()
  end

  @doc """
  The one-line `Usage:` string for a leaf, used both in `--help` and in usage errors.
  """
  @spec usage_line(JustBash.CLI.t(), [String.t()], Command.t()) :: String.t()
  def usage_line(cli, path, %Command{} = leaf) do
    tokens =
      Enum.map(leaf.flags, &flag_usage/1) ++ Enum.map(leaf.args, &arg_usage/1)

    "Usage: #{Enum.join([label(cli, path) | tokens], " ")}\n"
  end

  @doc """
  Error text for an unknown subcommand: a message, a "did you mean" suggestion when one
  is close enough, and a pointer to `--help`.
  """
  @spec unknown_subcommand(JustBash.CLI.t(), [String.t()], struct(), String.t()) :: String.t()
  def unknown_subcommand(cli, path, group, token) do
    attempted = Enum.join(path ++ [token], " ")

    suggestion =
      case suggest(group.commands, token) do
        nil -> ""
        name -> "Did you mean '#{Enum.join(path ++ [name], " ")}'?\n"
      end

    # Point `--help` at the group the unknown token was a child of (`acme pr --help`), not
    # always the root — that's where the available commands actually live.
    "#{cli.name}: unknown command '#{attempted}'\n" <>
      suggestion <> "Run '#{label(cli, path)} --help' for available commands.\n"
  end

  @doc """
  Error text for a group invoked without a subcommand: a message plus the group's
  command listing.
  """
  @spec missing_subcommand(JustBash.CLI.t(), [String.t()], struct()) :: String.t()
  def missing_subcommand(cli, path, group) do
    label = label(cli, path)

    "#{label}: missing subcommand\n" <>
      commands_section(group.commands) <>
      "Run '#{label} <command> --help' for more information on a command.\n"
  end

  # --- sections ---

  defp title(label, nil), do: "#{label}\n"
  defp title(label, doc), do: "#{label} - #{doc}\n"

  defp commands_section([]), do: ""

  defp commands_section(children) do
    rows = Enum.map(children, fn child -> {child.name, command_summary(child)} end)
    "Commands:\n" <> aligned_rows(rows)
  end

  defp command_summary(%Command{} = child) do
    suffix = if Command.group?(child), do: " (group)", else: ""
    "#{child.doc || ""}#{suffix}"
  end

  defp args_section([]), do: ""

  defp args_section(args) do
    rows = Enum.map(args, fn arg -> {"<#{arg.name}>", arg_detail(arg)} end)
    "Arguments:\n" <> aligned_rows(rows)
  end

  defp arg_detail(arg) do
    [arg[:doc], if(arg.required, do: "(required)")]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  defp options_section([]), do: ""

  defp options_section(flags) do
    rows = Enum.map(flags, fn {_name, spec} = flag -> {flag_label(flag), flag_detail(spec)} end)
    "Options:\n" <> aligned_rows(rows)
  end

  defp examples_section([]), do: ""

  defp examples_section(examples) do
    "Examples:\n" <>
      Enum.map_join(examples, "", fn
        %{cmd: cmd, doc: nil} -> "  #{cmd}\n"
        %{cmd: cmd, doc: doc} -> "  #{cmd}\n      #{doc}\n"
      end)
  end

  # --- flag/arg rendering ---

  # Left column for the detail list, e.g. "-v, --verbose" or "--report <int>".
  defp flag_label({_name, spec}) do
    forms =
      [spec[:short], spec[:long]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    case placeholder(spec) do
      nil -> forms
      ph -> "#{forms} #{ph}"
    end
  end

  defp flag_detail(spec) do
    [
      spec[:doc],
      values_note(spec[:values]),
      default_note(spec),
      if(spec[:required], do: "(required)")
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  defp values_note(nil), do: nil
  defp values_note(values), do: "(values: #{Enum.join(values, ", ")})"

  defp default_note(spec) do
    case {spec[:type], spec[:default]} do
      {:boolean, _} -> nil
      {_, nil} -> nil
      {_, default} -> "(default: #{default})"
    end
  end

  # Inline usage token, e.g. "--report <int>" (required) or "[--format text|json]".
  defp flag_usage({_name, spec}) do
    token =
      case placeholder(spec) do
        nil -> primary_form(spec)
        ph -> "#{primary_form(spec)} #{ph}"
      end

    if spec[:required], do: token, else: "[#{token}]"
  end

  defp primary_form(spec) do
    cond do
      spec[:type] == :boolean and spec[:short] -> spec[:short]
      spec[:long] -> spec[:long]
      true -> spec[:short]
    end
  end

  defp arg_usage(arg) do
    base = if arg.variadic, do: "<#{arg.name}>...", else: "<#{arg.name}>"
    if arg.required, do: base, else: "[#{base}]"
  end

  # Enum values render as a|b inline; otherwise a type placeholder; booleans have none.
  defp placeholder(spec) do
    case spec[:values] do
      nil -> type_placeholder(spec[:type])
      values -> Enum.join(values, "|")
    end
  end

  defp type_placeholder(:integer), do: "<int>"
  defp type_placeholder(:float), do: "<float>"
  defp type_placeholder(:string), do: "<string>"
  defp type_placeholder(:accumulator), do: "<string>"
  defp type_placeholder(_), do: nil

  # --- suggestions ---

  # Closest child name to `token` by Jaro distance, when confident enough.
  defp suggest(children, token) do
    children
    |> Enum.map(fn child -> {child.name, String.jaro_distance(child.name, token)} end)
    |> Enum.max_by(fn {_name, score} -> score end, fn -> nil end)
    |> case do
      {name, score} when score >= 0.7 -> name
      _ -> nil
    end
  end

  # --- formatting ---

  defp label(cli, path), do: Enum.join([cli.name | path], " ")

  # Two-column rows, left column padded to a common width.
  defp aligned_rows(rows) do
    width = rows |> Enum.map(fn {left, _} -> String.length(left) end) |> Enum.max(fn -> 0 end)

    rows
    |> Enum.map_join("", fn {left, right} ->
      if right == "" do
        "  #{left}\n"
      else
        "  #{String.pad_trailing(left, width)}   #{right}\n"
      end
    end)
  end

  # Join non-empty sections with a blank line between them, ending in a single newline.
  defp compact_join(sections) do
    sections
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.join("\n")
  end
end
