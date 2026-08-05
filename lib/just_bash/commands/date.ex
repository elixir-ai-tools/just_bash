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

  A directive is `%`, then field flags, then an optional width, then an optional
  locale modifier, then the conversion — `%_5Od` is all four at once. The flags
  are `-` (no padding), `_` (space padding), `0` (zero padding), `^` (upper case)
  and `#` (swap the conversion's default case). The modifiers are `E` and `O`,
  which select nothing in the C locale but are accepted only for the conversions
  GNU accepts them for; the rest pass through verbatim.

  None of that composes the way it reads. A flag reaches a numeric field and not
  a compound one, so `%-T` is "09:05:03" and only `%-D` loses its year padding;
  the last padding flag wins outright, so `%-0d` is "05"; a width *replaces* a
  conversion's own width rather than raising it, so `%1d` is "5"; and a modifier
  drops the padding flag entirely, so `%-Od` is "05". Every one of those rules is
  recorded in `test/fixtures/bash_cases/date_matrix.json` against real GNU date
  rather than reasoned about here — this paragraph describes the recording, it
  does not define it.

  An unrecognized directive is emitted verbatim (`%J` → `%J`), as GNU date does,
  so a caller can tell the difference between "not supported" and a real value.
  That passthrough is only safe because the supported set is complete enough that
  reaching it means the directive really does not exist: a directive that *is*
  real but unimplemented would print itself at exit 0, and a caller cannot tell
  that from a legitimate literal. The matrix enumerates the whole conversion
  alphabet — crossed with every flag, width and modifier — to keep it so.

  Flags: `-d` / `--date`, `-r SECONDS|FILE` / `--reference FILE`, `-I[FMT]` /
  `--iso-8601[=FMT]`, `-R` / `--rfc-email`, `-u` / `--utc` / `--universal`, the
  BSD `-v` adjustments, and the BSD `-j` / `-f` pair. A value may be attached or
  separate (`-d2024-06-15`, `--date=2024-06-15`), no-argument flags may cluster
  (`-ju`), and `--` ends option parsing — the getopt conventions real date
  inherits.

  `-r` reads both spellings the flag has in the wild, as FreeBSD's date does: a
  numeric value is epoch seconds, and anything else names a file whose
  modification time to report. GNU's `--reference` is always a file. The VFS
  records mtimes, so the file's time comes from the sandbox rather than the host
  clock, and a failure to read it reports the real error kind — descending
  through a regular file is ENOTDIR, not "no such file".

  `-d` and `-r` each name the instant to print, so giving both is an error rather
  than a silent choice between two answers.

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

  # `-d` and `-r` each name the instant to print. Accepting both would answer one
  # question with two answers and report success doing it.
  @exclusive "date: the options to specify dates for printing are mutually exclusive\n"

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
      {:ok, opts} -> report(bash, opts)
      {:error, msg} -> {Command.error(msg), bash}
    end
  end

  defp report(bash, %{reference: nil} = opts) do
    render_at(bash, opts, opts.datetime || DateTime.utc_now())
  end

  # `-r FILE` reports the file's modification time. The VFS records mtimes, so
  # this reads from the sandbox rather than the host clock.
  defp report(bash, %{reference: path} = opts) do
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
  defp parse_args(["--date", date_str | rest], opts), do: put_datetime(date_str, rest, opts)

  # -r takes an epoch timestamp or a file to read a modification time from.
  defp parse_args(["-r"], _opts), do: {:error, missing_argument("-r")}
  defp parse_args(["-r", value | rest], opts), do: put_epoch_or_reference(value, rest, opts)
  defp parse_args(["-r" <> value | rest], opts), do: put_epoch_or_reference(value, rest, opts)

  # GNU's spelling of the same flag names a file and only a file, so a numeric
  # value here is a file called "0" rather than the epoch.
  defp parse_args(["--reference=" <> path | rest], opts), do: put_reference(path, rest, opts)
  defp parse_args(["--reference", path | rest], opts), do: put_reference(path, rest, opts)

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

  # A long option is named in full, as GNU words it, where a short one is named
  # by its character. Either way "needs an argument" is a distinct error from
  # "no such flag" — the point of refusing a flag is that the message says what
  # to do differently.
  defp parse_args([flag], _opts) when flag in ["--date", "--reference"] do
    {:error, "date: option '#{flag}' requires an argument\n" <> usage()}
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

  # A reference file and a spelled-out instant each answer "which instant", so
  # giving both is an error rather than a silent choice between two answers. Two
  # spellings of the *same* kind still compose the way real date lets them: the
  # last one wins.
  defp put_datetime(_date_str, _rest, %{reference: reference}) when reference != nil,
    do: {:error, exclusive()}

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

  defp put_epoch(_seconds, _rest, %{reference: reference}) when reference != nil,
    do: {:error, exclusive()}

  defp put_epoch(seconds, rest, opts) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> parse_args(rest, %{opts | datetime: datetime})
      {:error, :invalid_unix_time} -> {:error, "date: invalid time\n"}
    end
  end

  defp put_reference(_path, _rest, %{datetime: datetime}) when datetime != nil,
    do: {:error, exclusive()}

  defp put_reference(path, rest, opts), do: parse_args(rest, %{opts | reference: path})

  defp exclusive, do: @exclusive <> usage()

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
  # Matching its shape says nothing about whether the number is a representable
  # instant, so the conversion has to be allowed to refuse it.
  defp parse_epoch("@" <> seconds) do
    case seconds |> String.to_integer() |> DateTime.from_unix() do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_format}
    end
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
  #
  # `yr_spec` is the padding flag a compound conversion forwards to the year
  # fields of its sub-format, and nil at the top level. See `yearish/3`.
  defp format_datetime(datetime, format), do: scan(format, datetime, nil, [])

  defp scan(<<>>, _datetime, _yr_spec, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # A trailing bare `%` is literal, as in real date.
  defp scan(<<?%>>, datetime, yr_spec, acc), do: scan(<<>>, datetime, yr_spec, ["%" | acc])

  defp scan(<<?%, rest::binary>>, datetime, yr_spec, acc) do
    {emitted, rest} = conversion(rest, datetime, yr_spec)
    scan(rest, datetime, yr_spec, [emitted | acc])
  end

  defp scan(<<char, rest::binary>>, datetime, yr_spec, acc) do
    scan(rest, datetime, yr_spec, [<<char>> | acc])
  end

  # A directive is `%`, field flags, an optional width, an optional locale
  # modifier, then the conversion — so the conversion character is not at a fixed
  # offset and the whole run has to be collected before anything can be rendered.
  defp conversion(input, datetime, yr_spec) do
    {flags, rest} = take_flags(input, [])
    {width, rest} = take_width(rest, [])
    {modifier, rest} = take_modifier(rest)
    decorated? = flags != [] or width != [] or modifier != nil

    ctx = %{
      flags: flags,
      width: width,
      modifier: modifier,
      yr_spec: yr_spec,
      prefix: [?%, flags, width, modifier || []]
    }

    case rest do
      # A decorated run cannot take `%` as its conversion. GNU emits the run
      # literally and begins a fresh directive at the `%`, so `%-%d` is `%-`
      # followed by `%d`, not a modified `%%`. The `%` is left unconsumed.
      <<?%, _::binary>> when decorated? -> {IO.iodata_to_binary(ctx.prefix), rest}
      # A run with no conversion at all is literal.
      <<>> -> {IO.iodata_to_binary(ctx.prefix), <<>>}
      _ -> render(rest, datetime, ctx)
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

  # POSIX's alternate-representation modifiers. In the C locale they select
  # nothing, but GNU still accepts them for some conversions and refuses them for
  # others, and a refusal is a verbatim passthrough — see `accepts_modifier?/2`.
  defp take_modifier(<<char, rest::binary>>) when char in [?E, ?O], do: {<<char>>, rest}
  defp take_modifier(input), do: {nil, input}

  # The colons of `%:z` belong to the directive rather than the flag run, and
  # `%z` is the only conversion that takes them.
  defp render(<<":::z", rest::binary>>, _dt, %{modifier: nil} = ctx),
    do: {emit({:zone, "0", 3}, ?z, ctx), rest}

  defp render(<<"::z", rest::binary>>, _dt, %{modifier: nil} = ctx),
    do: {emit({:zone, "0:00:00", 9}, ?z, ctx), rest}

  defp render(<<":z", rest::binary>>, _dt, %{modifier: nil} = ctx),
    do: {emit({:zone, "0:00", 6}, ?z, ctx), rest}

  defp render(<<char, rest::binary>>, dt, ctx), do: {convert(char, dt, ctx), rest}

  defp convert(char, dt, ctx) do
    case {field(char, dt, ctx), ctx.modifier} do
      {:unknown, _modifier} ->
        passthrough(char, ctx)

      {spec, nil} ->
        emit(spec, char, ctx)

      {spec, modifier} ->
        if accepts_modifier?(char, modifier) do
          # A modifier makes the conversion render its default form: the padding
          # flags are dropped and the width right-aligns whatever came out.
          spec
          |> emit(char, %{ctx | flags: Enum.reject(ctx.flags, &(&1 in [?-, ?_, ?0])), width: []})
          |> pad_string(ctx.width, ?\s)
        else
          passthrough(char, ctx)
        end
    end
  end

  # An unknown conversion is reconstructed verbatim, every part of the run
  # included, so the passthrough is byte-exact rather than approximately right.
  # `^` still reaches it: GNU renders `%^Ea` as "%^EA".
  defp passthrough(char, ctx) do
    ctx.prefix |> IO.iodata_to_binary() |> Kernel.<>(<<char>>) |> upcase_if(?^ in ctx.flags)
  end

  defp emit({:num, value, digits, pad}, char, ctx) do
    value
    |> pad_number(width_or(ctx.width, digits), padding_flag(ctx.flags) || pad)
    |> apply_case(char, ctx.flags)
  end

  defp emit({:zone, buf, digits}, char, ctx) do
    buf
    |> pad_zone(width_or(ctx.width, digits), padding_flag(ctx.flags) || ?0)
    |> apply_case(char, ctx.flags)
  end

  defp emit({:text, string}, char, ctx) do
    string
    |> apply_case(char, ctx.flags)
    |> pad_string(ctx.width, padding_flag(ctx.flags) || ?\s)
  end

  # A compound conversion is a sub-format, and its own padding flag reaches the
  # year fields inside it and nothing else: `%-D` is "01/05/5", where the month
  # and day keep the padding the year just lost.
  defp emit({:sub, subformat, dt}, char, ctx) do
    subformat
    |> scan(dt, padding_flag(ctx.flags), [])
    |> apply_case(char, ctx.flags)
    |> pad_string(ctx.width, padding_flag(ctx.flags) || ?\s)
  end

  # `%N` is a fractional-seconds field rather than a padded number: a width says
  # how many of its nine digits to print, extending with zeros past nine rather
  # than stopping, and the padding flags do not apply. GNU's handling of `_` and
  # `-` here is stranger still — `%_N` right-pads with spaces — and is recorded
  # as a known gap in the date matrix rather than guessed at.
  defp emit({:nanoseconds, dt}, _char, ctx), do: nanoseconds(dt, width_or(ctx.width, 9))

  defp width_or([], digits), do: digits
  defp width_or(width, _digits), do: to_int(width)

  defp to_int(width), do: width |> IO.iodata_to_binary() |> String.to_integer()

  # The last padding flag wins outright rather than folding one at a time: `-`
  # strips a field's padding, so applying `0` afterwards would have nothing left
  # to measure against — yet GNU renders `%-0d` as "05".
  defp padding_flag(flags), do: flags |> Enum.filter(&(&1 in [?-, ?_, ?0])) |> List.last()

  defp pad_number(value, digits, pad) do
    {sign, magnitude} =
      if value < 0,
        do: {"-", Integer.to_string(-value)},
        else: {"", Integer.to_string(value)}

    case pad do
      ?- -> sign <> magnitude
      ?_ -> String.pad_leading(sign <> magnitude, digits, " ")
      ?0 -> sign <> String.pad_leading(magnitude, max(digits - byte_size(sign), 0), "0")
    end
  end

  # The zone offset carries a sign that is always printed, and the width covers
  # it: `%_z` is "   +0" but `%0z` is "+0000", the same five columns filled from
  # opposite sides of the sign.
  defp pad_zone(buf, _digits, ?-), do: "+" <> buf
  defp pad_zone(buf, digits, ?_), do: String.pad_leading("+" <> buf, digits, " ")
  defp pad_zone(buf, digits, ?0), do: "+" <> String.pad_leading(buf, max(digits - 1, 0), "0")

  # A width pads text and compound conversions too, where no padding flag does —
  # except `-`, which suppresses padding here as everywhere.
  defp pad_string(string, [], _pad), do: string
  defp pad_string(string, _width, ?-), do: string
  defp pad_string(string, width, ?0), do: String.pad_leading(string, to_int(width), "0")
  defp pad_string(string, width, _pad), do: String.pad_leading(string, to_int(width), " ")

  # `^` upper-cases; `#` swaps whatever case the conversion's default has, which
  # is upper for the day and month names and lower for `%p` and `%Z`. `%P` is the
  # deliberately-lowercase spelling of `%p` and neither flag disturbs it, and `#`
  # does not reach `%c` though `^` does.
  defp apply_case(value, char, flags) do
    cond do
      ?# in flags and char in ~c"pPZ" -> String.downcase(value)
      ?# in flags and char in ~c"aAbBh" -> String.upcase(value)
      ?^ in flags and char != ?P -> String.upcase(value)
      true -> value
    end
  end

  defp upcase_if(value, true), do: String.upcase(value)
  defp upcase_if(value, false), do: value

  # Conversions GNU accepts each modifier for. Enumerated from real date in
  # `test/fixtures/bash_cases/date_matrix.json` rather than derived: the two sets
  # overlap without containing each other (`%Eq` renders, `%Oq` does not), and a
  # wrong guess shows up as a directive printing itself at exit 0.
  @e_conversions ~c"cCnpPqrRstTuxXyYzZ"
  @o_conversions ~c"bBCdegGhHIjklmMnNpPrRsStTuUVwWyzZ"

  defp accepts_modifier?(char, "E"), do: char in @e_conversions
  defp accepts_modifier?(char, "O"), do: char in @o_conversions

  # Compound conversions built from a sub-format, so the two can't drift and so
  # a forwarded padding flag reaches the same fields GNU's does.
  defp field(?F, dt, _ctx), do: {:sub, "%Y-%m-%d", dt}
  defp field(?D, dt, _ctx), do: {:sub, "%m/%d/%y", dt}
  defp field(?T, dt, _ctx), do: {:sub, "%H:%M:%S", dt}
  defp field(?R, dt, _ctx), do: {:sub, "%H:%M", dt}

  # `%c`, `%x`, `%X` and `%r` come from the locale rather than a GNU sub-format,
  # and no padding flag reaches them — `%-x` keeps the padding `%-D` drops, for
  # the same "%m/%d/%y". The year in `%c` has no four-digit minimum either.
  defp field(?c, dt, _ctx) do
    {:text,
     "#{short_day_name(dt)} #{short_month_name(dt)} #{space_pad2(dt.day)} " <>
       "#{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)} #{dt.year}"}
  end

  defp field(?x, dt, _ctx),
    do: {:text, "#{pad2(dt.month)}/#{pad2(dt.day)}/#{pad2(rem(dt.year, 100))}"}

  defp field(?X, dt, _ctx), do: {:text, "#{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)}"}

  defp field(?r, dt, _ctx) do
    {:text, "#{pad2(twelve_hour(dt.hour))}:#{pad2(dt.minute)}:#{pad2(dt.second)} #{meridiem(dt)}"}
  end

  defp field(?Y, dt, ctx), do: yearish(dt.year, 4, ctx)
  defp field(?G, dt, ctx), do: dt |> iso_week() |> elem(0) |> yearish(4, ctx)
  defp field(?y, dt, ctx), do: dt.year |> rem(100) |> yearish(2, ctx)
  defp field(?g, dt, ctx), do: dt |> iso_week() |> elem(0) |> rem(100) |> yearish(2, ctx)
  defp field(?C, dt, ctx), do: dt.year |> div(100) |> yearish(2, ctx)

  defp field(?m, dt, _ctx), do: {:num, dt.month, 2, ?0}
  defp field(?d, dt, _ctx), do: {:num, dt.day, 2, ?0}
  defp field(?H, dt, _ctx), do: {:num, dt.hour, 2, ?0}
  defp field(?M, dt, _ctx), do: {:num, dt.minute, 2, ?0}
  defp field(?S, dt, _ctx), do: {:num, dt.second, 2, ?0}
  defp field(?I, dt, _ctx), do: {:num, twelve_hour(dt.hour), 2, ?0}
  defp field(?j, dt, _ctx), do: {:num, Date.day_of_year(dt), 3, ?0}
  defp field(?u, dt, _ctx), do: {:num, Date.day_of_week(dt), 1, ?0}
  defp field(?w, dt, _ctx), do: {:num, rem(Date.day_of_week(dt), 7), 1, ?0}
  defp field(?q, dt, _ctx), do: {:num, div(dt.month - 1, 3) + 1, 1, ?0}
  defp field(?s, dt, _ctx), do: {:num, DateTime.to_unix(dt), 1, ?0}
  defp field(?V, dt, _ctx), do: {:num, dt |> iso_week() |> elem(1), 2, ?0}
  defp field(?U, dt, _ctx), do: {:num, week_of_year(dt, :sunday), 2, ?0}
  defp field(?W, dt, _ctx), do: {:num, week_of_year(dt, :monday), 2, ?0}

  # `%e`, `%k` and `%l` are the space-padded counterparts of `%d`, `%H` and `%I`.
  # The difference is a default pad character, not a different rendering.
  defp field(?e, dt, _ctx), do: {:num, dt.day, 2, ?_}
  defp field(?k, dt, _ctx), do: {:num, dt.hour, 2, ?_}
  defp field(?l, dt, _ctx), do: {:num, twelve_hour(dt.hour), 2, ?_}

  defp field(?z, _dt, _ctx), do: {:zone, "0", 5}

  defp field(?a, dt, _ctx), do: {:text, short_day_name(dt)}
  defp field(?A, dt, _ctx), do: {:text, full_day_name(dt)}
  defp field(?b, dt, _ctx), do: {:text, short_month_name(dt)}
  defp field(?h, dt, _ctx), do: {:text, short_month_name(dt)}
  defp field(?B, dt, _ctx), do: {:text, full_month_name(dt)}
  defp field(?p, dt, _ctx), do: {:text, meridiem(dt)}
  defp field(?P, dt, _ctx), do: {:text, dt |> meridiem() |> String.downcase()}
  defp field(?Z, dt, _ctx), do: {:text, dt.zone_abbr}
  defp field(?N, dt, _ctx), do: {:nanoseconds, dt}
  defp field(?n, _dt, _ctx), do: {:text, "\n"}
  defp field(?t, _dt, _ctx), do: {:text, "\t"}
  defp field(?%, _dt, _ctx), do: {:text, "%"}
  defp field(_other, _dt, _ctx), do: :unknown

  # A compound forwards its padding flag to the year fields of its sub-format,
  # and `%Y` loses its four-digit minimum there as well: `%-F` is "5-01-05" and
  # `%_F` is too, while `%_Y` on its own is "   5".
  defp yearish(value, digits, %{yr_spec: nil}), do: {:num, value, digits, ?0}
  defp yearish(value, 4, %{yr_spec: spec}), do: {:num, value, 0, spec}
  defp yearish(value, digits, %{yr_spec: spec}), do: {:num, value, digits, spec}

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
  defp space_pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, " ")

  defp meridiem(dt), do: if(dt.hour < 12, do: "AM", else: "PM")

  defp nanoseconds(dt, digits) do
    {microsecond, _precision} = dt.microsecond

    (microsecond * 1_000)
    |> Integer.to_string()
    |> String.pad_leading(9, "0")
    |> String.pad_trailing(digits, "0")
    |> binary_part(0, digits)
  end

  defp iso_week(dt), do: :calendar.iso_week_number({dt.year, dt.month, dt.day})

  # Days elapsed since the first `first_day` of the year, in whole weeks. Day of
  # year and day of week are both 1-based and the formula wants 0-based.
  defp week_of_year(dt, first_day) do
    weekday = Date.day_of_week(dt, first_day) - 1
    div(Date.day_of_year(dt) - 1 + 7 - weekday, 7)
  end

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
end
