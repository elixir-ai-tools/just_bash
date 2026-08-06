defmodule JustBash.FlagParser do
  @moduledoc """
  A shared module for parsing command-line flags in bash commands.

  Supports:
  - Boolean flags: `-a`, `-l`, `-v`
  - Combined flags: `-la` (equivalent to `-l -a`)
  - Value flags: `-n 10`, `-d ","` (flag that takes next argument)
  - Getopt clusters ending in a value flag: `-nk2` is `-n -k 2`
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
        value_labels: %{n: "number of lines"},
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
  - `:value_labels` - What an `:integer` flag counts, as GNU names it in
    `invalid number of lines: 'abc'`. Required for every `:integer` flag
  """

  @type flag_spec :: %{
          :boolean => [atom()],
          :value => [atom()],
          :defaults => map(),
          optional(:aliases) => map(),
          optional(:multi_value) => [atom()],
          optional(:integer) => [atom()],
          optional(:value_labels) => %{atom() => String.t()}
        }

  @type error ::
          {:unknown_flag, String.t()}
          | {:missing_value, String.t()}
          | {:invalid_value, String.t(), String.t()}

  @type parse_result :: {:ok, map(), [String.t()]} | {:error, error()}

  @doc """
  Parse command-line arguments according to the given flag specification.

  Returns `{:ok, flags, remaining_args}` where:
  - `flags` is a map containing all flag values
  - `remaining_args` is a list of non-flag arguments

  Returns `{:error, reason}` for the first argument that is flag-shaped but not
  in the spec, for a value flag with nothing after it, and for a value declared
  `:integer` that is not a number.

  ## Examples

      iex> spec = %{boolean: [:a, :l], value: [:n], integer: [:n], value_labels: %{n: "number of lines"}, defaults: %{a: false, l: false, n: 10}}
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

      iex> FlagParser.format_error("head", {:invalid_value, "number of lines", "abc"}, "")
      "head: invalid number of lines: 'abc'\\n"
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

  # GNU prints no `Try --help` line for a bad count, so neither do we.
  def format_error(command, {:invalid_value, label, value}, _usage),
    do: "#{command}: invalid #{label}: '#{value}'\n"

  defp do_parse([], _spec, flags, rest) do
    {:ok, flags, Enum.reverse(rest)}
  end

  defp do_parse(["--" | remaining], _spec, flags, rest) do
    {:ok, flags, Enum.reverse(rest) ++ remaining}
  end

  defp do_parse(["-" <> flag_str | remaining], spec, flags, rest) when flag_str != "" do
    case parse_flag(flag_str, remaining, spec, flags) do
      {:ok, new_flags, new_remaining} -> do_parse(new_remaining, spec, new_flags, rest)
      other -> other
    end
  end

  defp do_parse([arg | remaining], spec, flags, rest) do
    do_parse(remaining, spec, flags, [arg | rest])
  end

  defp parse_flag(flag_str, remaining, spec, flags) do
    lookup = flag_lookup(spec)
    flag_atom = Map.get(lookup, flag_str)

    cond do
      flag_atom in spec.boolean ->
        {:ok, Map.put(flags, flag_atom, true), remaining}

      flag_atom in value_flags(spec) ->
        take_value(flag_atom, flag_str, remaining, spec, flags)

      true ->
        parse_unnamed(flag_str, remaining, spec, flags, lookup)
    end
  end

  # A flag the spec does not name outright is a bare count (`head -5`), a
  # getopt cluster (`sort -nk2`), or an error.
  defp parse_unnamed("-" <> _ = long_flag_str, _remaining, _spec, _flags, _lookup) do
    {:error, {:unknown_flag, display_flag(long_flag_str)}}
  end

  defp parse_unnamed(flag_str, remaining, spec, flags, lookup) do
    case numeric_shorthand(flag_str, spec) do
      {:ok, count} ->
        {:ok, Map.put(flags, :n, count), remaining}

      :error ->
        parse_cluster(String.graphemes(flag_str), remaining, spec, flags, lookup)
    end
  end

  defp numeric_shorthand(flag_str, spec) do
    with true <- :n in spec.value,
         {count, ""} <- Integer.parse(flag_str) do
      {:ok, count}
    else
      _ -> :error
    end
  end

  # getopt walks a cluster one character at a time: booleans accumulate, and a
  # value flag takes the rest of the cluster as its argument — or the next
  # argument when it is the last character. It stops on the first character the
  # spec does not describe at all, so the diagnostic can never name a flag the
  # command implements.
  defp parse_cluster([], remaining, _spec, flags, _lookup), do: {:ok, flags, remaining}

  defp parse_cluster([char | rest], remaining, spec, flags, lookup) do
    flag_atom = Map.get(lookup, char)

    cond do
      flag_atom in spec.boolean ->
        parse_cluster(rest, remaining, spec, Map.put(flags, flag_atom, true), lookup)

      flag_atom in value_flags(spec) ->
        take_cluster_value(flag_atom, char, Enum.join(rest), remaining, spec, flags)

      true ->
        {:error, {:unknown_flag, char}}
    end
  end

  defp take_cluster_value(flag_atom, char, "", remaining, spec, flags) do
    take_value(flag_atom, char, remaining, spec, flags)
  end

  defp take_cluster_value(flag_atom, _char, attached, remaining, spec, flags) do
    with {:ok, value} <- parse_value(attached, flag_atom, spec) do
      {:ok, put_flag(flags, flag_atom, value, spec), remaining}
    end
  end

  defp take_value(flag_atom, _flag_str, [raw | rest], spec, flags) do
    with {:ok, value} <- parse_value(raw, flag_atom, spec) do
      {:ok, put_flag(flags, flag_atom, value, spec), rest}
    end
  end

  defp take_value(_flag_atom, flag_str, [], _spec, _flags) do
    {:error, {:missing_value, display_flag(flag_str)}}
  end

  defp flag_lookup(spec) do
    (spec.boolean ++ value_flags(spec))
    |> Map.new(fn atom -> {Atom.to_string(atom), atom} end)
    |> Map.merge(Map.get(spec, :aliases, %{}))
  end

  defp value_flags(spec), do: spec.value ++ Map.get(spec, :multi_value, [])

  # `parse/2` sees one leading `-` already stripped, so a long option arrives
  # here still carrying the second one.
  defp display_flag("-" <> _ = long_flag_str), do: "-" <> long_flag_str
  defp display_flag(short_flag_str), do: short_flag_str

  defp put_flag(flags, flag_atom, value, spec) do
    if flag_atom in Map.get(spec, :multi_value, []) do
      Map.put(flags, flag_atom, Map.get(flags, flag_atom, []) ++ [value])
    else
      Map.put(flags, flag_atom, value)
    end
  end

  # Only a flag declared `:integer` is a count. Coercing every value that looks
  # like one made `sort -t 1` a delimiter of `1` rather than `"1"`; handing back
  # a count that is not a number made `head -n abc` raise out of `Enum.take/2`.
  defp parse_value(value, flag_atom, spec) do
    if flag_atom in Map.get(spec, :integer, []) do
      parse_count(value, flag_atom, spec)
    else
      {:ok, value}
    end
  end

  defp parse_count(value, flag_atom, spec) do
    case Integer.parse(value) do
      {count, ""} -> {:ok, count}
      _ -> {:error, {:invalid_value, value_label(flag_atom, spec), value}}
    end
  end

  # A spec that declares `:integer` without saying what is being counted cannot
  # word the error, and that is a bug in the spec, not in the input.
  defp value_label(flag_atom, spec) do
    spec |> Map.fetch!(:value_labels) |> Map.fetch!(flag_atom)
  end
end
