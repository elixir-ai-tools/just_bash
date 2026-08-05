defmodule JustBash.Commands.Date do
  @moduledoc """
  The `date` command — display the current date and time.

  Output is always UTC. Supported directives:

    * compound — `%F` (`%Y-%m-%d`), `%T` (`%H:%M:%S`), `%R` (`%H:%M`),
      `%D` (`%m/%d/%y`), `%c`, `%x`, `%X`, `%r`
    * date — `%Y`, `%y`, `%C`, `%m`, `%d`, `%e` (space-padded), `%j`, `%q`,
      `%a`, `%A`, `%b`, `%h`, `%B`, `%u`, `%w`, `%G`, `%g`, `%U`, `%V`, `%W`
    * time — `%H`, `%M`, `%S`, `%N`, `%I`, `%k`, `%l`, `%p`, `%P`, `%Z`, `%s`
    * zone offset — `%z` (`+0000`), `%:z`, `%::z`, `%:::z`
    * literal — `%%`, `%n`, `%t`

  Directives accept GNU's field flags between the `%` and the conversion:
  `-` (no padding), `_` (space padding), `0` (zero padding), `^` (upper case) and
  `#` (also upper case, for conversions whose default is mixed case). A numeric
  field width may follow the flags, as in `%03d`.

  An unrecognized directive is emitted verbatim (`%J` → `%J`), as GNU date does,
  so a caller can tell the difference between "not supported" and a real value.
  That passthrough is only safe because the supported set is complete enough that
  reaching it means the directive really does not exist: a directive that *is*
  real but unimplemented would print itself at exit 0, and a caller cannot tell
  that from a legitimate literal. `test/fixtures/bash_cases/date_matrix.json`
  enumerates the whole conversion alphabet against real GNU date to keep it so.

  Flags: `-d` / `--date=`, `-r SECONDS|FILE` / `--reference=FILE`, `-I[FMT]` /
  `--iso-8601[=FMT]`, `-R` / `--rfc-email`, `-u` / `--utc` / `--universal`, the
  BSD `-v` adjustments, and the BSD `-j` / `-f` pair. Values may be attached or
  separate (`-d2024-06-15`), no-argument flags may cluster (`-ju`), and `--` ends
  option parsing — the getopt conventions real date inherits.

  `-r` reads both spellings the flag has in the wild, as FreeBSD's date does: a
  numeric value is epoch seconds, and anything else names a file whose
  modification time to report. GNU's `--reference=FILE` is always a file. The VFS
  records mtimes, so the file's time comes from the sandbox rather than the host
  clock, and a failure to read it reports the real error kind — descending
  through a regular file is ENOTDIR, not "no such file".

  Everything else is an error. An unimplemented flag must not be dropped:
  ignoring it would print the current date at exit 0, which a caller cannot
  tell apart from a real answer.

  Errors follow whichever real implementation spells the flag: GNU's wording for
  a long option (`unrecognized option '--foo'`), BSD's for a short one
  (`illegal option -- X`), since BSD names a long option by its second `-` and
  so identifies nothing.

  One BSD feature is deliberately partial, and says so rather than guessing:
  `-v` implements only the relative form (`[+-]val[ymwdHMS]`), not the
  set-a-field form (`-v1d`, `-vfri`).
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @default_format "%a %b %d %H:%M:%S UTC %Y"
  @rfc_format "%a, %d %b %Y %H:%M:%S %z"

  # The flags that each name an output format. They compete rather than compose,
  # so setting one when another is already set is an error however it arrived.
  @format_keys [:format, :iso_format, :rfc_format]

  # `-v[+-]val[unit]`. The sign is what distinguishes an adjustment from BSD's
  # set-this-field form, which we do not implement.
  @adjustment ~r/^([+-])(\d+)([ymwdHMS])$/

  # Real date's operand is a time to set the system clock to. There is no clock
  # to set here, and an unprivileged real date fails on it too.
  @settable_time ~r/^(\d{2}){2,6}(\.\d{2})?$/

  # Short flags that take no value, and so may cluster: `-ju` is `-j -u`.
  @no_argument_flags [?j, ?u, ?R]

  # The ISO calendar spans fewer than 3.7M days, so no adjustment larger than
  # that lands inside it from any base.
  @max_seconds 3_652_425 * 86_400

  # Seconds per unit, each rounded down to the shortest that unit can be, so the
  # bound above never rejects an adjustment that would have been in range.
  @unit_seconds %{
    "y" => 365 * 86_400,
    "m" => 28 * 86_400,
    "w" => 7 * 86_400,
    "d" => 86_400,
    "H" => 3_600,
    "M" => 60,
    "S" => 1
  }

  @impl true
  def names, do: ["date"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:ok, opts} -> emit(bash, opts)
      {:error, msg} -> {Command.error(msg), bash}
    end
  end

  defp emit(bash, %{reference: nil} = opts) do
    render_at(bash, opts, opts.datetime || DateTime.utc_now())
  end

  # A reference file's modification time. The VFS records mtimes, so this reads
  # from the sandbox rather than the host clock.
  defp emit(bash, %{reference: path} = opts) do
    case FS.stat(bash.fs, FS.resolve_path(bash.cwd, path)) do
      {:ok, %{mtime: mtime}, fs} -> render_at(%{bash | fs: fs}, opts, mtime)
      {:error, error} -> {Command.error("date: #{path}: #{FS.strerror(error)}\n"), bash}
    end
  end

  defp render_at(bash, opts, datetime) do
    case adjust(datetime, opts.adjustments) do
      {:ok, adjusted} ->
        format = opts.format || opts.iso_format || opts.rfc_format || @default_format
        {Command.ok(format_datetime(adjusted, format) <> "\n"), bash}

      {:error, msg} ->
        {Command.error(msg), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      format: nil,
      iso_format: nil,
      rfc_format: nil,
      datetime: nil,
      reference: nil,
      input_format: nil,
      adjustments: [],
      no_set: false
    })
  end

  defp parse_args([], opts), do: finish(opts)

  defp parse_args(["+" <> format | rest], opts),
    do: put_format(:format, format, rest, opts, &parse_args/2)

  defp parse_args(["-I" <> spec | rest], opts), do: put_iso_format(spec, rest, opts)
  defp parse_args(["--iso-8601" | rest], opts), do: put_iso_format("", rest, opts)

  defp parse_args(["--iso-8601=" <> spec | rest], opts), do: put_iso_format(spec, rest, opts)

  # A flag's value may be attached (-d2024-01-01) or separate, as getopt allows.
  defp parse_args(["-d"], _opts), do: {:error, missing_argument("-d")}
  defp parse_args(["-d", date_str | rest], opts), do: put_datetime(date_str, rest, opts)
  defp parse_args(["-d" <> date_str | rest], opts), do: put_datetime(date_str, rest, opts)
  defp parse_args(["--date=" <> date_str | rest], opts), do: put_datetime(date_str, rest, opts)

  # -r takes an epoch timestamp or a file to read a modification time from.
  defp parse_args(["-r"], _opts), do: {:error, missing_argument("-r")}
  defp parse_args(["-r", value | rest], opts), do: put_epoch_or_reference(value, rest, opts)
  defp parse_args(["-r" <> value | rest], opts), do: put_epoch_or_reference(value, rest, opts)

  # GNU's spelling of the same flag names a file and only a file, so a numeric
  # value here is a file called "0" rather than the epoch.
  defp parse_args(["--reference=" <> path | rest], opts), do: put_reference(path, rest, opts)

  # BSD date: -v adjusts a field of the date, as many times as given.
  defp parse_args(["-v"], _opts), do: {:error, missing_argument("-v")}
  defp parse_args(["-v", spec | rest], opts), do: put_adjustment(spec, rest, opts)
  defp parse_args(["-v" <> spec | rest], opts), do: put_adjustment(spec, rest, opts)

  # BSD date: -j flag means "don't set the date" (just display)
  defp parse_args(["-j" | rest], opts) do
    parse_args(rest, %{opts | no_set: true})
  end

  # BSD date: -f input_format to parse a date string
  defp parse_args(["-f"], _opts), do: {:error, missing_argument("-f")}

  defp parse_args(["-f", input_format | rest], opts) do
    parse_args(rest, %{opts | input_format: input_format})
  end

  # Output is always UTC, so -u is accepted and changes nothing.
  defp parse_args([flag | rest], opts) when flag in ["-u", "--utc", "--universal"] do
    parse_args(rest, opts)
  end

  defp parse_args([flag | rest], opts) when flag in ["-R", "--rfc-email"] do
    put_format(:rfc_format, @rfc_format, rest, opts, &parse_args/2)
  end

  # Inside a cluster the next character is an option character, and `-` is not
  # one. This clause has to precede the rewrite below, which would otherwise read
  # `-u-` as `-u --` and print the date at exit 0.
  defp parse_args([<<?-, flag, ?-, _::binary>> | _rest], _opts)
       when flag in @no_argument_flags do
    {:error, "date: illegal option -- -\n" <> usage()}
  end

  # getopt lets no-argument flags cluster, and lets whichever flag ends a cluster
  # carry its value attached: `-ur0` is `-u -r 0`.
  defp parse_args([<<?-, flag, rest::binary>> | args], opts)
       when flag in @no_argument_flags and rest != "" do
    parse_args([<<?-, flag>>, "-" <> rest | args], opts)
  end

  # When we have an input_format set (BSD -f flag) and encounter a non-option arg
  defp parse_args([<<c, _::binary>> = date_str | rest], %{input_format: input_format} = opts)
       when input_format != nil and c != ?+ and c != ?- do
    put_formatted_date(date_str, rest, opts, &parse_args/2)
  end

  # `--` ends option parsing, as getopt does.
  defp parse_args(["--" | rest], opts), do: parse_operands(rest, opts)

  # An option we do not implement fails loudly. Dropping it would print the
  # current date at exit 0 — a wrong answer nothing downstream can detect.
  defp parse_args(["--" <> flag | _rest], _opts) when flag != "" do
    {:error, "date: unrecognized option '--#{flag}'\n" <> usage()}
  end

  # A short option is named by the character getopt rejected, so `-Xu` is a bad
  # `X` rather than a bad `Xu`. A lone `-` has no such character and falls
  # through to the operand clause below, which is where getopt leaves it too.
  defp parse_args([<<?-, char, _::binary>> | _rest], _opts) do
    {:error, "date: illegal option -- #{<<char>>}\n" <> usage()}
  end

  defp parse_args([operand | _rest], opts), do: operand_error(operand, opts)

  # After `--` nothing is an option, so an argument is `+format`, the operand a
  # pending -f describes, or a time we are being asked to set the clock to.
  defp parse_operands([], opts), do: finish(opts)

  defp parse_operands(["+" <> format | rest], opts),
    do: put_format(:format, format, rest, opts, &parse_operands/2)

  defp parse_operands([date_str | rest], %{input_format: input_format} = opts)
       when input_format != nil do
    put_formatted_date(date_str, rest, opts, &parse_operands/2)
  end

  defp parse_operands([operand | _rest], opts), do: operand_error(operand, opts)

  # -f names the format of an operand. With no operand there is nothing to parse,
  # and real date prints usage rather than falling back to the current time.
  defp finish(%{input_format: input_format}) when input_format != nil, do: {:error, usage()}
  defp finish(opts), do: {:ok, opts}

  # With -j there is no clock to set, so an operand is a time to display — and
  # the canonical `[[[[mm]dd]HH]MM[[cc]yy][.SS]` form is one we cannot parse.
  defp operand_error(_operand, %{no_set: true}), do: {:error, illegal_time_format()}

  defp operand_error(operand, _opts) do
    if Regex.match?(@settable_time, operand) do
      {:error, "date: clock_settime: Operation not permitted\n"}
    else
      {:error, illegal_time_format()}
    end
  end

  # Real date rejects competing output formats rather than picking one, whichever
  # pair of flags they arrived through.
  defp put_format(key, format, rest, opts, cont) do
    if Enum.any?(@format_keys, &(Map.fetch!(opts, &1) != nil)) do
      {:error, "date: multiple output formats specified\n"}
    else
      cont.(rest, Map.put(opts, key, format))
    end
  end

  defp put_formatted_date(date_str, rest, %{input_format: input_format} = opts, cont) do
    case parse_formatted_date(date_str, input_format) do
      {:ok, datetime} -> cont.(rest, %{opts | datetime: datetime, input_format: nil})
      {:error, _} -> {:error, "date: invalid date '#{date_str}'\n"}
    end
  end

  defp put_datetime(date_str, rest, opts) do
    case parse_date_string(date_str) do
      {:ok, datetime} -> parse_args(rest, %{opts | datetime: datetime})
      {:error, _} -> {:error, "date: invalid date '#{date_str}'\n"}
    end
  end

  # `-r` reads both spellings the flag has in the wild, the way FreeBSD's date
  # does: a number is epoch seconds, and anything else names a file. Falling back
  # to the file is what makes an unparseable value an error about that file
  # rather than a "not a number" the caller cannot act on.
  defp put_epoch_or_reference(value, rest, opts) do
    case Integer.parse(value) do
      {seconds, ""} -> put_epoch(seconds, rest, opts)
      _not_a_number -> put_reference(value, rest, opts)
    end
  end

  defp put_epoch(seconds, rest, opts) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> parse_args(rest, %{opts | datetime: datetime})
      {:error, :invalid_unix_time} -> {:error, "date: invalid time\n"}
    end
  end

  defp put_reference(path, rest, opts), do: parse_args(rest, %{opts | reference: path})

  defp put_adjustment(spec, rest, opts) do
    case parse_adjustment(spec) do
      {:ok, adjustment} ->
        parse_args(rest, %{opts | adjustments: [adjustment | opts.adjustments]})

      :error ->
        {:error, cannot_adjust(spec)}
    end
  end

  # An adjustment too large for the ISO calendar is rejected here, before it is
  # applied, and not by the range check in adjust/2 afterwards. That is not just
  # an early exit: a fixed-length unit is applied with DateTime.add/3, whose cost
  # grows with how far the result lands from the epoch, so a spec like
  # `+99999999999999999999d` does not come back at all.
  defp parse_adjustment(spec) do
    with [_spec, sign, value, unit] <- Regex.run(@adjustment, spec),
         amount = String.to_integer(sign <> value),
         true <- abs(amount) * Map.fetch!(@unit_seconds, unit) <= @max_seconds do
      {:ok, {amount, unit, spec}}
    else
      _unparseable_or_too_large -> :error
    end
  end

  defp cannot_adjust(spec), do: "date: #{spec}: Cannot apply date adjustment\n" <> usage()

  defp missing_argument(flag), do: "date: option requires an argument -- #{flag}\n" <> usage()

  defp illegal_time_format, do: "date: illegal time format\n" <> usage()

  defp usage do
    """
    usage: date [-u] [-d datestr | -r seconds|file] [-j] [-f input_fmt]
                [-I[date|hours|minutes|seconds|ns]] [-v[+|-]val[y|m|w|d|H|M|S]]
                [+output_fmt]
    """
  end

  # Adjustments are applied in the order given, each to the result of the last,
  # which is how BSD composes `-v+1m -v-1d`. An adjustment that lands outside the
  # ISO calendar is rejected rather than printed: `%Y` is four digits and `-d`
  # only parses ISO dates, so a year like -97973 is not an answer.
  defp adjust(datetime, adjustments) do
    adjustments
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, datetime}, fn {_n, _unit, spec} = adjustment, {:ok, dt} ->
      case apply_adjustment(dt, adjustment) do
        %DateTime{year: year} = adjusted when year in 0..9999 -> {:cont, {:ok, adjusted}}
        %DateTime{} -> {:halt, {:error, cannot_adjust(spec)}}
      end
    end)
  end

  defp apply_adjustment(dt, {n, "y", _spec}), do: shift_years(dt, n)
  defp apply_adjustment(dt, {n, "m", _spec}), do: shift_months(dt, n)
  defp apply_adjustment(dt, {n, "w", _spec}), do: DateTime.add(dt, n * 7, :day)
  defp apply_adjustment(dt, {n, "d", _spec}), do: DateTime.add(dt, n, :day)
  defp apply_adjustment(dt, {n, "H", _spec}), do: DateTime.add(dt, n, :hour)
  defp apply_adjustment(dt, {n, "M", _spec}), do: DateTime.add(dt, n, :minute)
  defp apply_adjustment(dt, {n, "S", _spec}), do: DateTime.add(dt, n, :second)

  # A year adjustment moves the year field and lets an impossible result
  # normalize forward: Feb 29 plus a year is Mar 1. BSD really does differ here
  # from the month adjustment below, which clamps instead — `-v+1y` off Feb 29
  # gives Mar 1 where `-v+12m` gives Feb 28.
  defp shift_years(dt, n) do
    year = dt.year + n
    days = Calendar.ISO.days_in_month(year, dt.month)

    case dt.day - days do
      overflow when overflow > 0 -> shift_months(%{dt | year: year, day: overflow}, 1)
      _fits -> %{dt | year: year}
    end
  end

  # Months are a variable-length unit, so BSD preserves the day of the month and
  # clamps to the target month's last day when it doesn't exist there: May 31
  # plus a month is June 30.
  defp shift_months(dt, n) do
    total = dt.year * 12 + (dt.month - 1) + n
    year = Integer.floor_div(total, 12)
    month = Integer.mod(total, 12) + 1
    %{dt | year: year, month: month, day: min(dt.day, Calendar.ISO.days_in_month(year, month))}
  end

  defp put_iso_format(spec, rest, opts) do
    case iso_format(spec) do
      {:ok, format} -> put_format(:iso_format, format, rest, opts, &parse_args/2)
      :error -> {:error, "date: invalid argument '#{spec}' for '--iso-8601'\n"}
    end
  end

  defp iso_format(spec) when spec in ["", "date"], do: {:ok, "%Y-%m-%d"}
  defp iso_format("hours"), do: {:ok, "%Y-%m-%dT%H+00:00"}
  defp iso_format("minutes"), do: {:ok, "%Y-%m-%dT%H:%M+00:00"}
  defp iso_format("seconds"), do: {:ok, "%Y-%m-%dT%H:%M:%S+00:00"}
  defp iso_format("ns"), do: {:ok, "%Y-%m-%dT%H:%M:%S,%N+00:00"}
  defp iso_format(_spec), do: :error

  defp parse_formatted_date(date_str, format) do
    cond do
      format == "%Y-%m-%d %H:%M:%S" -> parse_space_datetime(date_str)
      format == "%Y-%m-%d" -> parse_date_only(date_str)
      format == "%Y-%m-%dT%H:%M:%S" -> parse_iso_datetime(date_str)
      true -> parse_date_string(date_str)
    end
  end

  defp parse_date_string(str) do
    cond do
      str =~ ~r/^@-?\d+$/ -> parse_epoch(str)
      str =~ ~r/^\d{4}-\d{2}-\d{2}$/ -> parse_date_only(str)
      str =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/ -> parse_iso_datetime(str)
      str =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/ -> parse_space_datetime(str)
      true -> parse_relative_date(str)
    end
  end

  # `@N` is seconds since the epoch, the one -d form that is not a calendar date.
  defp parse_epoch("@" <> seconds) do
    {:ok, seconds |> String.to_integer() |> DateTime.from_unix!()}
  end

  defp parse_date_only(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
      error -> error
    end
  end

  # An ISO timestamp with no offset is UTC here, but DateTime.from_iso8601/1
  # requires one, so supply it rather than rejecting the most common spelling.
  defp parse_iso_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, :missing_offset} -> parse_utc_datetime(str <> "Z")
      _error -> {:error, :invalid_format}
    end
  end

  defp parse_utc_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _error -> {:error, :invalid_format}
    end
  end

  defp parse_space_datetime(str) do
    iso_str = String.replace(str, " ", "T") <> "Z"

    case DateTime.from_iso8601(iso_str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_relative_date("now"), do: {:ok, DateTime.utc_now()}

  defp parse_relative_date("yesterday"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(-86_400, :second)}

  defp parse_relative_date("tomorrow"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(86_400, :second)}

  defp parse_relative_date(_), do: {:error, :invalid_format}

  # A single left-to-right scan consumes each directive exactly once, so `%%`
  # escaping works — chained String.replace/3 cannot express it (`%%Y` became
  # `%2024`). Unknown directives pass through verbatim (`%J` -> `%J`), matching
  # GNU date. The scan is byte-wise, not codepoint-wise: format strings are raw
  # binaries and need not be valid UTF-8; every known directive is ASCII, and
  # passthrough reconstructs other bytes verbatim either way.
  defp format_datetime(datetime, format), do: scan(format, datetime, [])

  defp scan(<<>>, _datetime, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # A trailing bare `%` is literal, as in real date.
  defp scan(<<?%>>, datetime, acc), do: scan(<<>>, datetime, ["%" | acc])

  # GNU allows field flags and a width between the `%` and the conversion, so the
  # conversion character is not at a fixed offset. The modifier run is collected
  # first, then applied to whatever the conversion rendered.
  defp scan(<<?%, rest::binary>>, datetime, acc) do
    {emitted, rest} = conversion(rest, datetime)
    scan(rest, datetime, [emitted | acc])
  end

  defp scan(<<char, rest::binary>>, datetime, acc) do
    scan(rest, datetime, [<<char>> | acc])
  end

  # `%:z`, `%::z` and `%:::z` are the only conversions where colons are part of
  # the directive rather than a modifier, so they are matched before flag parsing.
  defp conversion(<<":::z", rest::binary>>, dt), do: {zone_offset(dt, :hours), rest}
  defp conversion(<<"::z", rest::binary>>, dt), do: {zone_offset(dt, :seconds), rest}
  defp conversion(<<":z", rest::binary>>, dt), do: {zone_offset(dt, :minutes), rest}

  defp conversion(input, dt) do
    {flags, input} = take_flags(input, [])
    {width, input} = take_width(input, [])
    modified? = flags != [] or width != []

    case input do
      # A flag run cannot take `%` as its conversion. GNU emits the flags
      # literally and begins a fresh directive at the `%`, so `%-%d` is `%-`
      # followed by `%d`, not a modified `%%`. The `%` is left unconsumed.
      <<?%, _::binary>> when modified? ->
        {IO.iodata_to_binary([?%, flags, width]), input}

      # A trailing `%` — with any modifiers that followed it — is literal.
      <<>> ->
        {IO.iodata_to_binary([?%, flags, width]), <<>>}

      <<char, rest::binary>> ->
        {render(char, dt, flags, width), rest}
    end
  end

  defp take_flags(<<char, rest::binary>>, acc) when char in [?-, ?_, ?0, ?^, ?#] do
    take_flags(rest, [char | acc])
  end

  defp take_flags(input, acc), do: {Enum.reverse(acc), input}

  defp take_width(<<char, rest::binary>>, acc) when char in ?0..?9 do
    take_width(rest, [char | acc])
  end

  defp take_width(input, acc), do: {Enum.reverse(acc), input}

  # `%N` is a fractional-seconds field rather than a padded number, so a width
  # truncates its nine digits instead of padding them (`%3N` is "000", not "000"
  # widened) and the padding flags do not apply. GNU's handling of `_` and `-`
  # here is stranger still — `%_N` right-pads with spaces — and is recorded as a
  # known gap in the date matrix rather than guessed at.
  defp render(?N, dt, _flags, []), do: nanoseconds(dt)
  defp render(?N, dt, _flags, width), do: String.slice(nanoseconds(dt), 0, to_int(width))

  # An unknown conversion is reconstructed verbatim, modifiers included, so the
  # passthrough is byte-exact rather than approximately right.
  defp render(char, dt, flags, width) do
    case directive(char, dt) do
      {:unknown, verbatim} -> IO.iodata_to_binary([?%, flags, width, verbatim])
      rendered -> rendered |> pad(flags, width) |> upcase(flags)
    end
  end

  # Padding is decided once from the whole flag run rather than folded flag by
  # flag. `-` strips the field's padding, so applying `0` afterwards would have
  # nothing left to measure against — yet GNU renders `%-0d` as "05", because the
  # last padding flag wins outright.
  defp pad(rendered, flags, width) do
    case padding_flag(flags) do
      # `-` suppresses padding, and a width alongside it is ignored.
      ?- -> unpadded(rendered)
      ?_ -> String.pad_leading(unpadded(rendered), field_width(rendered, width), " ")
      ?0 -> String.pad_leading(unpadded(rendered), field_width(rendered, width), "0")
      # No padding flag: an explicit width still pads, with zeros. Without one the
      # conversion's own padding stands, which is how `%e`, `%k` and `%l` keep the
      # spaces that distinguish them from `%d`, `%H` and `%I`.
      nil when width != [] -> String.pad_leading(unpadded(rendered), to_int(width), "0")
      nil -> rendered
    end
  end

  defp padding_flag(flags), do: flags |> Enum.filter(&(&1 in [?-, ?_, ?0])) |> List.last()

  defp field_width(rendered, []), do: String.length(rendered)
  defp field_width(_rendered, width), do: to_int(width)

  defp to_int(width), do: width |> IO.iodata_to_binary() |> String.to_integer()

  # The conversion's own padding, removed so a flag can restate it. A field that
  # is all padding ("00" for midnight) still has to print one digit.
  defp unpadded(rendered) do
    case rendered |> String.trim_leading("0") |> String.trim_leading(" ") do
      "" -> "0"
      trimmed -> trimmed
    end
  end

  # Both `^` and `#` upper-case here. GNU documents `#` as case-swapping, but
  # every conversion whose default is mixed case (`%a`, `%A`, `%b`, `%B`, `%p`)
  # swaps to upper, and the rest have no case to swap.
  defp upcase(value, flags) do
    if Enum.any?(flags, &(&1 in [?^, ?#])), do: String.upcase(value), else: value
  end

  # Compound directives are composed from their single-field parts so the two
  # can't drift.
  defp directive(?F, dt), do: "#{directive(?Y, dt)}-#{directive(?m, dt)}-#{directive(?d, dt)}"
  defp directive(?T, dt), do: "#{directive(?H, dt)}:#{directive(?M, dt)}:#{directive(?S, dt)}"
  defp directive(?R, dt), do: "#{directive(?H, dt)}:#{directive(?M, dt)}"
  defp directive(?D, dt), do: "#{directive(?m, dt)}/#{directive(?d, dt)}/#{directive(?y, dt)}"
  defp directive(?x, dt), do: directive(?D, dt)
  defp directive(?X, dt), do: directive(?T, dt)

  defp directive(?r, dt),
    do: "#{directive(?I, dt)}:#{directive(?M, dt)}:#{directive(?S, dt)} #{directive(?p, dt)}"

  defp directive(?c, dt) do
    "#{directive(?a, dt)} #{directive(?b, dt)} #{directive(?e, dt)} #{directive(?T, dt)} #{directive(?Y, dt)}"
  end

  defp directive(?Y, dt), do: dt.year |> Integer.to_string() |> String.pad_leading(4, "0")
  defp directive(?m, dt), do: pad2(dt.month)
  defp directive(?d, dt), do: pad2(dt.day)
  defp directive(?H, dt), do: pad2(dt.hour)
  defp directive(?M, dt), do: pad2(dt.minute)
  defp directive(?S, dt), do: pad2(dt.second)
  defp directive(?y, dt), do: dt.year |> rem(100) |> pad2()
  defp directive(?C, dt), do: dt.year |> div(100) |> pad2()
  # `%e` is space-padded rather than zero-padded — the one directive where the
  # difference is visible in column-aligned output.
  defp directive(?e, dt), do: dt.day |> Integer.to_string() |> String.pad_leading(2, " ")
  defp directive(?I, dt), do: dt.hour |> twelve_hour() |> pad2()
  defp directive(?p, dt), do: if(dt.hour < 12, do: "AM", else: "PM")
  defp directive(?P, dt), do: ?p |> directive(dt) |> String.downcase()
  defp directive(?Z, dt), do: dt.zone_abbr

  defp directive(?N, dt), do: nanoseconds(dt)

  defp directive(?s, dt), do: Integer.to_string(DateTime.to_unix(dt))
  defp directive(?a, dt), do: short_day_name(dt)
  defp directive(?A, dt), do: full_day_name(dt)
  defp directive(?b, dt), do: short_month_name(dt)
  defp directive(?h, dt), do: short_month_name(dt)
  defp directive(?B, dt), do: full_month_name(dt)
  defp directive(?j, dt), do: day_of_year(dt)
  defp directive(?u, dt), do: Integer.to_string(Date.day_of_week(dt))
  defp directive(?w, dt), do: Integer.to_string(rem(Date.day_of_week(dt), 7))
  defp directive(?q, dt), do: dt.month |> then(&(div(&1 - 1, 3) + 1)) |> Integer.to_string()

  # `%k` and `%l` are the space-padded counterparts of `%H` and `%I`.
  defp directive(?k, dt), do: dt.hour |> Integer.to_string() |> String.pad_leading(2, " ")

  defp directive(?l, dt),
    do: dt.hour |> twelve_hour() |> Integer.to_string() |> String.pad_leading(2, " ")

  # ISO week numbering runs on its own year: 2019-12-30 is week 1 of 2020. Erlang
  # already implements the rule, so %G/%V defer to it rather than restating it.
  defp directive(?G, dt), do: dt |> iso_week() |> elem(0) |> Integer.to_string()
  defp directive(?g, dt), do: dt |> iso_week() |> elem(0) |> rem(100) |> pad2()
  defp directive(?V, dt), do: dt |> iso_week() |> elem(1) |> pad2()

  # %U counts weeks from the first Sunday, %W from the first Monday. Both are
  # plain division of the elapsed days, unlike the ISO rule above.
  defp directive(?U, dt), do: dt |> week_of_year(:sunday) |> pad2()
  defp directive(?W, dt), do: dt |> week_of_year(:monday) |> pad2()

  defp directive(?z, dt), do: zone_offset(dt, :compact)
  defp directive(?n, _dt), do: "\n"
  defp directive(?t, _dt), do: "\t"
  defp directive(?%, _dt), do: "%"
  defp directive(other, _dt), do: {:unknown, <<other>>}

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp nanoseconds(dt) do
    {microsecond, _precision} = dt.microsecond
    (microsecond * 1_000) |> Integer.to_string() |> String.pad_leading(9, "0")
  end

  defp iso_week(dt), do: :calendar.iso_week_number({dt.year, dt.month, dt.day})

  # Days elapsed since the first `first_day` of the year, in whole weeks. Day of
  # year and day of week are both 1-based and the formula wants 0-based.
  defp week_of_year(dt, first_day) do
    weekday = Date.day_of_week(dt, first_day) - 1
    div(Date.day_of_year(dt) - 1 + 7 - weekday, 7)
  end

  # Output is always UTC, so the offset is fixed; only its spelling varies.
  defp zone_offset(_dt, :compact), do: "+0000"
  defp zone_offset(_dt, :minutes), do: "+00:00"
  defp zone_offset(_dt, :seconds), do: "+00:00:00"
  defp zone_offset(_dt, :hours), do: "+00"

  defp twelve_hour(0), do: 12
  defp twelve_hour(hour) when hour > 12, do: hour - 12
  defp twelve_hour(hour), do: hour

  defp short_day_name(dt) do
    case Date.day_of_week(dt) do
      1 -> "Mon"
      2 -> "Tue"
      3 -> "Wed"
      4 -> "Thu"
      5 -> "Fri"
      6 -> "Sat"
      7 -> "Sun"
    end
  end

  defp full_day_name(dt) do
    case Date.day_of_week(dt) do
      1 -> "Monday"
      2 -> "Tuesday"
      3 -> "Wednesday"
      4 -> "Thursday"
      5 -> "Friday"
      6 -> "Saturday"
      7 -> "Sunday"
    end
  end

  defp short_month_name(dt) do
    Enum.at(
      ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec),
      dt.month - 1
    )
  end

  defp full_month_name(dt) do
    Enum.at(
      ~w(January February March April May June July August September October November December),
      dt.month - 1
    )
  end

  defp day_of_year(dt) do
    Date.day_of_year(dt) |> Integer.to_string() |> String.pad_leading(3, "0")
  end
end
