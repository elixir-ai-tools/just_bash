defmodule JustBash.FlagParser do
  @moduledoc """
  A shared module for parsing command-line flags in bash commands.

  Supports:
  - Boolean flags: `-a`, `-l`, `-v`
  - Combined flags: `-la` (equivalent to `-l -a`)
  - Value flags: `-n 10`, `-d ","` (flag that takes next argument)
  - Stop parsing at `--`

  ## Usage

      # Define your flag spec
      spec = %{
        boolean: [:a, :l, :v, :r],
        value: [:n, :d],
        defaults: %{a: false, l: false, v: false, r: false, n: 10, d: nil}
      }

      # Parse arguments
      {flags, rest} = FlagParser.parse(args, spec)

  ## Flag Specification

  - `:boolean` - List of single-character atoms for boolean flags
  - `:value` - List of single-character atoms for flags that take a value
  - `:defaults` - Map of default values for all flags
  """

  @type flag_spec :: %{
          :boolean => [atom()],
          :value => [atom()],
          :defaults => map(),
          optional(:aliases) => map()
        }

  @type parse_result :: {map(), [String.t()]}

  @doc """
  Parse command-line arguments according to the given flag specification.

  Returns a tuple of `{flags, remaining_args}` where:
  - `flags` is a map containing all flag values
  - `remaining_args` is a list of non-flag arguments

  ## Examples

      iex> spec = %{boolean: [:a, :l], value: [:n], defaults: %{a: false, l: false, n: 10}}
      iex> FlagParser.parse(["-a", "-n", "5", "file.txt"], spec)
      {%{a: true, l: false, n: 5}, ["file.txt"]}

      iex> spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}
      iex> FlagParser.parse(["-al", "dir"], spec)
      {%{a: true, l: true}, ["dir"]}
  """
  @spec parse([String.t()], flag_spec()) :: parse_result()
  def parse(args, spec) do
    do_parse(args, spec, spec.defaults, [])
  end

  defp do_parse([], _spec, flags, rest) do
    {flags, Enum.reverse(rest)}
  end

  defp do_parse(["--" | remaining], _spec, flags, rest) do
    {flags, Enum.reverse(rest) ++ remaining}
  end

  defp do_parse(["-" <> flag_str | remaining], spec, flags, rest) when flag_str != "" do
    case parse_flag(flag_str, remaining, spec, flags) do
      {:ok, new_flags, new_remaining} ->
        do_parse(new_remaining, spec, new_flags, rest)

      :not_a_flag ->
        do_parse(remaining, spec, flags, ["-" <> flag_str | rest])
    end
  end

  defp do_parse([arg | remaining], spec, flags, rest) do
    do_parse(remaining, spec, flags, [arg | rest])
  end

  defp parse_flag(flag_str, remaining, spec, flags) do
    # Check for aliases first
    aliases = Map.get(spec, :aliases, %{})
    flag_atom = Map.get(aliases, flag_str, String.to_atom(flag_str))

    cond do
      flag_atom in spec.boolean ->
        {:ok, Map.put(flags, flag_atom, true), remaining}

      flag_atom in spec.value ->
        case remaining do
          [value | rest] ->
            parsed_value = parse_value(value)
            {:ok, Map.put(flags, flag_atom, parsed_value), rest}

          [] ->
            :not_a_flag
        end

      String.length(flag_str) > 1 ->
        case parse_combined_flags(flag_str, spec, flags) do
          {:ok, new_flags} -> {:ok, new_flags, remaining}
          :error -> try_numeric_flag(flag_str, remaining, spec, flags)
        end

      true ->
        try_numeric_flag(flag_str, remaining, spec, flags)
    end
  end

  defp parse_combined_flags(flag_str, spec, flags) do
    chars = String.graphemes(flag_str)

    if Enum.all?(chars, &(String.to_atom(&1) in spec.boolean)) do
      new_flags =
        Enum.reduce(chars, flags, fn char, acc ->
          Map.put(acc, String.to_atom(char), true)
        end)

      {:ok, new_flags}
    else
      :error
    end
  end

  defp try_numeric_flag(flag_str, remaining, spec, flags) do
    if :n in spec.value do
      case Integer.parse(flag_str) do
        {num, ""} ->
          {:ok, Map.put(flags, :n, num), remaining}

        _ ->
          :not_a_flag
      end
    else
      :not_a_flag
    end
  end

  defp parse_value(value) do
    case Integer.parse(value) do
      {num, ""} -> num
      _ -> value
    end
  end
end
