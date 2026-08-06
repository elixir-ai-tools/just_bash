defmodule JustBash.FlagParser do
  @moduledoc """
  A shared module for parsing command-line flags in bash commands.

  Supports:
  - Boolean flags: `-a`, `-l`, `-v`
  - Combined flags: `-la` (equivalent to `-l -a`)
  - Value flags: `-n 10`, `-d ","` (flag that takes next argument)
  - Stop parsing at `--`

  A flag the spec does not describe is an error, never an operand. Demoting it
  turned `sort -Q file` into a read of a file named `-Q`, which sort reports as
  nothing at all: empty stdout, empty stderr, exit 0. Callers get
  `{:error, {:unknown_flag, flag}}` and report it with `format_error/3`.

  ## Usage

      # Define your flag spec
      spec = %{
        boolean: [:a, :l, :v, :r],
        value: [:n, :d],
        integer: [:n],
        defaults: %{a: false, l: false, v: false, r: false, n: 10, d: nil}
      }

      # Parse arguments
      case FlagParser.parse(args, spec) do
        {:ok, flags, rest} -> ...
        {:error, reason} -> FlagParser.format_error("ls", reason, @usage)
      end

  ## Flag Specification

  - `:boolean` - List of single-character atoms for boolean flags
  - `:value` - List of single-character atoms for flags that take a value
  - `:defaults` - Map of default values for all flags
  - `:aliases` - Map of flag string to atom, for spellings that are not the
    atom itself (`"R" => :r`, `"-recursive" => :r`)
  - `:multi_value` - Value flags that accumulate a list instead of overwriting
  - `:integer` - Value flags whose value is a count. Only these are converted;
    everything else stays a string, so `sort -t 1` is the delimiter `"1"`
  """

  @type flag_spec :: %{
          :boolean => [atom()],
          :value => [atom()],
          :defaults => map(),
          optional(:aliases) => map(),
          optional(:multi_value) => [atom()],
          optional(:integer) => [atom()]
        }

  @type error :: {:unknown_flag, String.t()} | {:missing_value, String.t()}

  @type parse_result :: {:ok, map(), [String.t()]} | {:error, error()}

  @doc """
  Parse command-line arguments according to the given flag specification.

  Returns `{:ok, flags, remaining_args}` where:
  - `flags` is a map containing all flag values
  - `remaining_args` is a list of non-flag arguments

  Returns `{:error, reason}` for the first argument that is flag-shaped but not
  in the spec, or for a value flag with nothing after it.

  ## Examples

      iex> spec = %{boolean: [:a, :l], value: [:n], integer: [:n], defaults: %{a: false, l: false, n: 10}}
      iex> FlagParser.parse(["-a", "-n", "5", "file.txt"], spec)
      {:ok, %{a: true, l: false, n: 5}, ["file.txt"]}

      iex> spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}
      iex> FlagParser.parse(["-al", "dir"], spec)
      {:ok, %{a: true, l: true}, ["dir"]}

      iex> spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}
      iex> FlagParser.parse(["-Q", "dir"], spec)
      {:error, {:unknown_flag, "Q"}}
  """
  @spec parse([String.t()], flag_spec()) :: parse_result()
  def parse(args, spec) do
    do_parse(args, spec, spec.defaults, [])
  end

  @doc """
  Render a `parse/2` error the way GNU coreutils words it, followed by `usage`.

  A short option is named by its character and a long option in full, because
  that is the unit that was rejected — `-laQ` is a bad `Q`, and
  `invalid option -- '-'` for `--nope` identifies nothing.

  ## Examples

      iex> FlagParser.format_error("sort", {:unknown_flag, "Q"}, "")
      "sort: invalid option -- 'Q'\\n"

      iex> FlagParser.format_error("sort", {:unknown_flag, "--nope"}, "")
      "sort: unrecognized option '--nope'\\n"
  """
  @spec format_error(String.t(), error(), String.t()) :: String.t()
  def format_error(command, {:unknown_flag, "--" <> _ = flag}, usage),
    do: "#{command}: unrecognized option '#{flag}'\n" <> usage

  def format_error(command, {:unknown_flag, flag}, usage),
    do: "#{command}: invalid option -- '#{flag}'\n" <> usage

  def format_error(command, {:missing_value, "--" <> _ = flag}, usage),
    do: "#{command}: option '#{flag}' requires an argument\n" <> usage

  def format_error(command, {:missing_value, flag}, usage),
    do: "#{command}: option requires an argument -- '#{flag}'\n" <> usage

  defp do_parse([], _spec, flags, rest) do
    {:ok, flags, Enum.reverse(rest)}
  end

  defp do_parse(["--" | remaining], _spec, flags, rest) do
    {:ok, flags, Enum.reverse(rest) ++ remaining}
  end

  defp do_parse(["-" <> flag_str | remaining], spec, flags, rest) when flag_str != "" do
    case parse_flag(flag_str, remaining, spec, flags) do
      {:ok, new_flags, new_remaining} ->
        do_parse(new_remaining, spec, new_flags, rest)

      {:error, _reason} = error ->
        error
    end
  end

  defp do_parse([arg | remaining], spec, flags, rest) do
    do_parse(remaining, spec, flags, [arg | rest])
  end

  defp parse_flag(flag_str, remaining, spec, flags) do
    aliases = Map.get(spec, :aliases, %{})
    lookup = flag_lookup(spec)
    flag_atom = Map.get(aliases, flag_str) || Map.get(lookup, flag_str)

    cond do
      flag_atom in spec.boolean ->
        {:ok, Map.put(flags, flag_atom, true), remaining}

      flag_atom in spec.value or flag_atom in Map.get(spec, :multi_value, []) ->
        take_value(flag_atom, flag_str, remaining, spec, flags)

      String.length(flag_str) > 1 ->
        combined_lookup = Map.merge(lookup, aliases)

        with :error <- try_attached_value_flag(flag_str, spec, flags, combined_lookup),
             :error <- parse_combined_flags(flag_str, spec, flags, combined_lookup) do
          try_numeric_flag(flag_str, remaining, spec, flags)
        else
          {:ok, new_flags} -> {:ok, new_flags, remaining}
        end

      true ->
        try_numeric_flag(flag_str, remaining, spec, flags)
    end
  end

  defp take_value(flag_atom, _flag_str, [value | rest], spec, flags) do
    {:ok, put_flag(flags, flag_atom, parse_value(value, flag_atom, spec), spec), rest}
  end

  defp take_value(_flag_atom, flag_str, [], _spec, _flags) do
    {:error, {:missing_value, display_flag(flag_str)}}
  end

  defp try_attached_value_flag(flag_str, spec, flags, lookup) do
    <<first_char::binary-size(1), rest::binary>> = flag_str
    flag_atom = Map.get(lookup, first_char)
    multi_value = Map.get(spec, :multi_value, [])

    if flag_atom != nil and (flag_atom in spec.value or flag_atom in multi_value) and rest != "" do
      {:ok, put_flag(flags, flag_atom, parse_value(rest, flag_atom, spec), spec)}
    else
      :error
    end
  end

  defp parse_combined_flags(flag_str, spec, flags, lookup) do
    atoms = Enum.map(String.graphemes(flag_str), &Map.get(lookup, &1))

    if Enum.all?(atoms, &(&1 in spec.boolean)) do
      {:ok, Enum.reduce(atoms, flags, fn atom, acc -> Map.put(acc, atom, true) end)}
    else
      :error
    end
  end

  defp flag_lookup(spec) do
    (spec.boolean ++ spec.value ++ Map.get(spec, :multi_value, []))
    |> Map.new(fn atom -> {Atom.to_string(atom), atom} end)
  end

  defp try_numeric_flag(flag_str, remaining, spec, flags) do
    with true <- :n in spec.value,
         {num, ""} <- Integer.parse(flag_str) do
      {:ok, Map.put(flags, :n, num), remaining}
    else
      _ -> unknown_flag(flag_str, spec)
    end
  end

  defp unknown_flag("-" <> _ = long_flag_str, _spec) do
    {:error, {:unknown_flag, display_flag(long_flag_str)}}
  end

  # Out of a cluster, getopt stops on the first character the spec does not
  # describe as a boolean flag, so that is what is named — not the cluster.
  defp unknown_flag(flag_str, spec) do
    lookup = Map.merge(flag_lookup(spec), Map.get(spec, :aliases, %{}))

    offender =
      flag_str
      |> String.graphemes()
      |> Enum.find(flag_str, fn char -> Map.get(lookup, char) not in spec.boolean end)

    {:error, {:unknown_flag, offender}}
  end

  # `parse/2` sees one leading `-` already stripped, so a long option arrives
  # here still carrying the second one.
  defp display_flag("-" <> _ = long_flag_str), do: "-" <> long_flag_str
  defp display_flag(short_flag_str), do: short_flag_str

  defp put_flag(flags, flag_atom, value, spec) do
    multi_value = Map.get(spec, :multi_value, [])

    if flag_atom in multi_value do
      existing = Map.get(flags, flag_atom, [])
      Map.put(flags, flag_atom, existing ++ [value])
    else
      Map.put(flags, flag_atom, value)
    end
  end

  # Only a flag declared `:integer` is a count. Coercing every value that looks
  # like one made `sort -t 1` a delimiter of `1` rather than `"1"`.
  defp parse_value(value, flag_atom, spec) do
    with true <- flag_atom in Map.get(spec, :integer, []),
         {num, ""} <- Integer.parse(value) do
      num
    else
      _ -> value
    end
  end
end
