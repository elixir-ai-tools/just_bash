defmodule Mix.Tasks.BashFixtures.Gen do
  @moduledoc """
  Generates enumerated fixture matrices — the cases nobody thinks to write.

  The corpus grew by example: someone fixed a bug, then wrote a case for the shape
  they had just fixed. That leaves whole alphabets unexamined. `date.json` has 30
  hand-written cases and covers none of `%F`, `%D`, `%T`, `%R`, `-I` or `-v` — the
  exact directives that shipped emitting themselves literally at exit 0, which an
  agent then used as if it were a date.

  A command's flag and directive sets are *finite*. They are not a space to sample
  with a fuzzer; they are a list to enumerate. This task writes that enumeration
  out as ordinary case files, so recording and comparison work exactly as they do
  for hand-written cases:

      mix bash_fixtures.gen date       # write the matrix
      mix bash_fixtures date_matrix    # record what real bash does
      mix test --only suite:date_matrix

  Generated suites are named `<matrix>_matrix` and are safe to regenerate: the
  digest in `JustBash.Fixtures` is content-derived, so a case that did not change
  keeps its recording.

  ## Matrices

    * `date` — every strftime conversion alone, adjacently paired, and crossed
      with every field flag, locale modifier, width and compound form, plus `-I`
      granularities, `-d` input forms, and flags GNU date does not have

  A list of conversions and a list of flags are each easy to write down. The
  cross of the two is where the bugs live and is what nobody enumerates by hand:
  the first version of this matrix listed both alphabets and still missed that
  `%-T` rendered "9:05:03", because it never asked a flag and a conversion in the
  same breath. Cross what you enumerate.

  ## Usage

      mix bash_fixtures.gen              # every matrix
      mix bash_fixtures.gen date         # one matrix
      mix bash_fixtures.gen --dry-run    # report counts, write nothing
  """

  use Mix.Task

  alias JustBash.Fixtures
  alias Mix.Tasks.BashFixtures

  @shortdoc "Generate enumerated fixture matrices"

  # Every conversion GNU date documents, plus the padding and timezone-colon
  # modifiers. Enumerated rather than curated: the point is that no human decides
  # which of these is interesting.
  @date_directives ~w(
    a A b B c C d D e F g G h H I j k l m M n N p P q r R s S t T u U V w W x X y Y z Z
  )

  # The five GNU field flags. Crossed with every conversion below rather than
  # sampled: which conversions a flag reaches is exactly the fact no one writes
  # down, and `%-T` rendered "9:05:03" for want of a case that asked.
  @date_flags ["-", "_", "0", "^", "#"]

  # POSIX's locale modifiers. GNU accepts them for some conversions and rejects
  # them for others, and which is which is not guessable — enumerated so the
  # recording decides.
  @date_locale_modifiers ["E", "O"]

  @date_modifiers [":z", "::z", ":::z", "-d", "_d", "0d", "^a", "#a"]

  # The timezone conversions are the only ones whose directive contains colons,
  # so a flag run reaches them through a different path than every other
  # conversion. GNU splits the field width across the sign, hours and minutes.
  @date_zone_forms [
    "%-:z",
    "%_:z",
    "%0:z",
    "%3:z",
    "%8:z",
    "%-::z",
    "%_::z",
    "%-:::z",
    "%^:z",
    "%-z",
    "%_z",
    "%0z",
    "%1z",
    "%5z",
    "%8z",
    "%^z",
    "%#z"
  ]

  # A width applies to text and compound conversions too, where no padding flag
  # does. Both facts are only visible when the two are asked separately.
  @date_string_widths [
    "%5a",
    "%_5a",
    "%05a",
    "%-5a",
    "%^5a",
    "%2a",
    "%12D",
    "%12T",
    "%_12F",
    "%012F",
    "%20c",
    "%6p",
    "%6Z"
  ]

  # Modifier crossed with flags and widths. GNU drops the padding flag when a
  # modifier is present and right-aligns the default rendering instead.
  @date_modifier_forms [
    "%-Od",
    "%_5Od",
    "%3Od",
    "%05Ed",
    "%0Ey",
    "%5EY",
    "%-Ey",
    "%_5Ey",
    "%-Oe",
    "%_OH",
    "%^Ec",
    "%#Ec",
    "%^Ea",
    "%^Oa",
    "%E",
    "%O",
    "%EJ",
    "%OJ",
    "%O%d",
    "%E%d",
    "%EOd",
    "%OEd"
  ]

  # Adjacent pairs catch a formatter that rescans its own output. A chain of
  # String.replace/3 ending in %% -> % turned %%Y into %2024, and no single
  # directive can expose that.
  @date_pairs [
    "%%F",
    "%%%F",
    "%F%T",
    "%Y%m%d",
    "%%",
    "%%%%",
    "%",
    "%F%",
    "%J",
    "%%J",
    "%F%J%T",
    # A flag run cannot take `%` as its conversion, so these are not the modified
    # `%%` they look like. Found by the existing composition property, pinned here.
    "%#%!",
    "%-%d",
    "%#%%",
    "%--d",
    "%0-d",
    "%^%a",
    # A flag run with no conversion at all is literal.
    "%#",
    "%-",
    "%_",
    "%0",
    "%^",
    "%^!",
    # Passthrough is not inert: `^` upper-cases the reconstruction it emits, so
    # `%^Ea` is "%^EA". Every flag is asked against an unknown conversion.
    "%^J",
    "%#J",
    "%-J",
    "%_J",
    "%0J",
    "%_3J",
    "%0!",
    "%^!x",
    "%0d%-d",
    "%_H:%-M"
  ]

  # Field width crossed with padding flags. Only meaningful at the single-digit
  # base, and only here is it visible that the last padding flag wins outright:
  # `%-0d` is "05", not the "5" that folding the flags in order would give.
  @date_widths [
    "%3d",
    "%03d",
    "%_3d",
    "%-3d",
    "%_10d",
    "%^3a",
    "%-0d",
    "%0_d",
    "%_2H",
    "%_3H",
    "%-d",
    "%-H",
    "%-M",
    "%-e",
    "%_e",
    "%0e",
    "%-I",
    "%-j",
    # A width narrower than the field is not a floor: GNU replaces the
    # conversion's own width outright, so `%1d` is "5" and not "05".
    "%1d",
    "%1e",
    "%1H",
    "%0d",
    "%5e",
    "%5k",
    "%5l",
    "%5Y",
    "%_5Y",
    "%5s",
    "%_5j",
    "%_1j",
    "%2j"
  ]

  # %N is a fractional-seconds field: a width sets how many of its nine digits
  # are printed, extending with zeros past nine rather than stopping. GNU's
  # handling of the space and no-pad flags here is stranger — `%_N` right-pads
  # with spaces, which no other conversion does — so those combinations are
  # recorded as gaps rather than imitated.
  @nanosecond_gap "GNU pads %N with trailing spaces under _ and -, unlike every other conversion"

  @date_nanoseconds ~w(%N %-N %0N %^N %#N %1N %3N %6N %9N %12N %_N %-3N %_6N %-12N)

  # Gaps keyed by the format that provokes them, because the same format arrives
  # through several enumerations — `%_N` is both a nanosecond case and a cell in
  # the flag cross, and a gap marked in one place and not the other is a failure
  # nobody can act on.
  @format_gaps %{
    "%_N" => @nanosecond_gap,
    "%-3N" => @nanosecond_gap,
    "%_6N" => @nanosecond_gap,
    "%-12N" => @nanosecond_gap
  }

  @date_iso ["-I", "-Idate", "-Ihours", "-Iminutes", "-Iseconds", "-Ins", "--iso-8601=date"]

  # -d forms an agent would plausibly reach for. Relative forms are anchored to a
  # fixed base date so they stay deterministic. GNU accepts a whole date grammar
  # here; the relative half is unimplemented, and these cases record what it owes.
  @relative_gap "GNU relative date grammar for -d is not implemented"

  @date_inputs [
    {"2024-06-15", nil},
    {"2024-06-15 13:30:00", nil},
    {"2024-06-15T13:30:00", nil},
    {"@1718458200", nil},
    {"@0", nil},
    {"@-1", nil},
    # Shape-checking `@N` with a regexp says nothing about whether the number is
    # a representable instant. GNU refuses; a converter that trusts the shape
    # raises out of the command instead.
    {"@99999999999999999999", nil},
    {"@-99999999999999999999", nil},
    {"2024-06-15 13:30:00 +1 day", @relative_gap},
    {"2024-06-15 13:30:00 1 day ago", @relative_gap},
    {"2024-06-15 13:30:00 +6 months", @relative_gap},
    {"2024-06-15 13:30:00 6 months ago", @relative_gap},
    {"2024-06-15 13:30:00 next tuesday", @relative_gap},
    {"2024-06-15 13:30:00 last monday", @relative_gap},
    {"2024-06-15 13:30:00 +2 weeks", @relative_gap},
    {"2024-06-15 13:30:00 -3 hours", @relative_gap}
  ]

  # A flag this shell does not implement must produce an error, not today's date
  # at exit 0 — that is what these cases are for, and most of them assert it
  # against GNU date directly.
  #
  # The exceptions are the BSD spellings JustBash documents as supported: it
  # accepts what GNU refuses, so the recording is kept and the divergence named
  # rather than silently tolerated.
  @bsd_gap "-j/-f are supported as documented BSD spellings; GNU date rejects them"
  @bsd_adjust_gap "-v is a supported BSD adjustment here; GNU date rejects it"

  # Both shells refuse an unknown flag; only the wording differs. JustBash spells
  # a short option's refusal the way BSD does, since that is the implementation
  # that names the offending character.
  @bsd_usage_gap "the refusal is BSD-worded (illegal option, usage) where GNU says invalid option"

  @date_absent_flags [
    {"-v+6m", @bsd_adjust_gap},
    {"-v +6m", @bsd_adjust_gap},
    {"-v-1d", @bsd_adjust_gap},
    {"-j", @bsd_gap},
    {"-j -f %Y", @bsd_gap},
    # Not the `-j -f` pair above: a clustered `-jf` is one token. Both engines
    # refuse it, but for different reasons and so in different words — GNU has
    # no `-j` at all, where this one splits the cluster and then finds `-f` with
    # nothing to parse.
    {"-jf %Y", @bsd_usage_gap},
    {"--not-a-flag", @bsd_usage_gap},
    {"-Z", @bsd_usage_gap}
  ]

  # An operand that is not a `+FORMAT` is how BSD spells "set the system clock"
  # and how GNU spells "extra operand". Both engines refuse it and neither runs;
  # the recorded difference is only which of the two refusals is printed.
  @operand_gap "an operand is refused as a BSD settable time, not as a GNU extra operand"

  # Three base instants, because one cannot distinguish padding. At day 15 and
  # hour 13, `%-d`, `%_d` and `%0d` all render "15" and every padding bug hides;
  # at day 5 and hour 9 they render "5", " 5" and "05". The single-digit base also
  # puts the hour before noon, so %I/%p/%P/%l/%k differ from the afternoon base.
  #
  # June cannot expose the year-relative fields: `%j`, `%U`, `%V` and `%W` are all
  # three- or two-digit there whatever the flag. The January base is where their
  # padding becomes visible.
  @base "2024-06-15 13:30:00"
  @base_single "2024-06-05 09:05:03"
  @base_january "2005-01-05 09:05:03"

  # A fourth, used only for the fields whose padding needs a year below 1000:
  # `%Y`, `%G` and `%C` are already at their full width in any modern year.
  @base_low_year "0005-01-05 09:05:03"

  @low_year_forms ["%Y", "%-Y", "%_Y", "%0Y", "%5Y", "%G", "%-G", "%C", "%-C", "%y", "%-y", "%-g"]

  # A compound conversion is a sub-format, and a padding flag reaches some of its
  # fields and not others: `%-D` is "01/05/5" — the year loses its padding while
  # the month and day keep theirs — but `%-x`, the same "%m/%d/%y", is untouched.
  # Which compounds forward the flag is not derivable, so all of them are asked,
  # at the one base where a four-digit year can lose padding.
  @date_compounds ~w(F D T R c r x X)

  @bases [{"pm", @base}, {"am", @base_single}, {"jan", @base_january}]

  @impl Mix.Task
  def run(args) do
    {opts, matrices, _} = OptionParser.parse(args, switches: [dry_run: :boolean])
    dry_run? = Keyword.get(opts, :dry_run, false)

    matrices
    |> resolve()
    |> Enum.each(&write_matrix(&1, dry_run?))
  end

  defp resolve([]), do: ["date"]

  defp resolve(names) do
    Enum.each(names, fn name ->
      unless name in ["date"], do: Mix.raise("Unknown matrix: #{name}")
    end)

    names
  end

  defp write_matrix(name, dry_run?) do
    suite = "#{name}_matrix"
    cases = build(name)

    Mix.shell().info("#{suite}: #{length(cases)} cases")

    unless dry_run? do
      path = Path.join(BashFixtures.cases_dir(), "#{suite}.json")
      BashFixtures.write_json!(path, %{"suite" => suite, "cases" => cases})
      Mix.shell().info("  wrote #{Path.relative_to_cwd(path)}")
    end
  end

  defp build("date"), do: date_cases()

  defp date_cases do
    Enum.concat([
      conversion_cases(),
      cross_cases(),
      shape_cases(),
      argument_cases()
    ])
  end

  # Each conversion on its own, at every base instant.
  defp conversion_cases do
    Enum.concat([
      for d <- @date_directives, {label, base} <- @bases do
        date_case("directive %#{d} (#{label})", "'+%#{d}'", base)
      end,
      for m <- @date_modifiers, {label, base} <- @bases do
        date_case("modifier %#{m} (#{label})", "'+%#{m}'", base)
      end,
      for f <- @low_year_forms do
        date_case("low year #{f}", "'+#{f}'", @base_low_year)
      end,
      for f <- @date_nanoseconds do
        format_case("nanoseconds", f, @base_single)
      end
    ])
  end

  # The crosses. A flag list and a conversion list are each finite and each easy
  # to write down; which pairs of them mean anything is neither, so every pair is
  # asked rather than the interesting-looking ones.
  defp cross_cases do
    Enum.concat([
      for flag <- @date_flags, d <- @date_directives do
        format_case("flag", "%#{flag}#{d}", @base_january)
      end,
      # E and O are accepted for some conversions and refused for others, and the
      # refusal is a verbatim passthrough at exit 0 — the failure this whole
      # matrix exists to make impossible to ship unnoticed.
      for mod <- @date_locale_modifiers, d <- @date_directives do
        date_case("locale modifier %#{mod}#{d}", "'+%#{mod}#{d}'", @base_january)
      end,
      for flag <- @date_flags, c <- @date_compounds do
        date_case("compound %#{flag}#{c}", "'+%#{flag}#{c}'", @base_low_year)
      end
    ])
  end

  # Directive shapes that are not a plain conversion: colons, widths, adjacency.
  defp shape_cases do
    Enum.concat([
      for f <- @date_zone_forms do
        date_case("zone #{f}", "'+#{f}'", @base_january)
      end,
      for f <- @date_string_widths do
        date_case("string width #{f}", "'+#{f}'", @base_january)
      end,
      for f <- @date_modifier_forms do
        date_case("modifier form #{f}", "'+#{f}'", @base_january)
      end,
      for f <- @date_pairs do
        date_case("sequence #{f}", "'+#{f}'")
      end,
      for f <- @date_widths do
        date_case("width #{f}", "'+#{f}'", @base_single)
      end
    ])
  end

  # Everything before the format string: flags, their arguments, and operands.
  defp argument_cases do
    Enum.concat([
      for flag <- @date_iso do
        date_case("iso #{flag}", flag)
      end,
      for {flag, gap} <- @date_absent_flags do
        # No -d: these must fail on the flag itself, not on date parsing.
        one_case(
          "absent flag #{flag}",
          "TZ=UTC LC_ALL=C date #{flag} '+%Y-%m-%d'; echo rc=$?",
          gap
        )
      end,
      for {input, gap} <- @date_inputs do
        one_case(
          "input #{input}",
          "TZ=UTC LC_ALL=C date -d '#{input}' '+%Y-%m-%d %H:%M:%S'; echo rc=$?",
          gap
        )
      end,
      [
        # -r reads a file's mtime, which differs between the two engines' clocks,
        # so only its deterministic paths are enumerated here. The success path is
        # covered by a unit test against a seeded mtime.
        one_case(
          "reference -r on a missing file",
          "TZ=UTC LC_ALL=C date -r /jb_definitely_missing '+%F'; echo rc=$?"
        ),
        # Both engines refuse each of these; only the wording of the refusal
        # differs, so the exit code is the assertion and the message is the gap.
        one_case(
          "reference -r with no argument",
          "TZ=UTC LC_ALL=C date -r; echo rc=$?",
          @bsd_usage_gap
        ),
        one_case(
          "date -d with no argument",
          "TZ=UTC LC_ALL=C date -d; echo rc=$?",
          @bsd_usage_gap
        ),
        one_case(
          "long --date with no argument",
          "TZ=UTC LC_ALL=C date --date; echo rc=$?",
          @bsd_usage_gap
        ),
        one_case(
          "long --reference with no argument",
          "TZ=UTC LC_ALL=C date --reference; echo rc=$?",
          @bsd_usage_gap
        ),
        # -d and -r each name the instant to print, so asking for both is a
        # question with two answers. Silently preferring one reports success.
        one_case(
          "reference -r and -d together",
          "touch /tmp/jb_r_$$; TZ=UTC LC_ALL=C date -r /tmp/jb_r_$$ -d '#{@base}' '+%F'; echo rc=$?; rm -f /tmp/jb_r_$$",
          @bsd_usage_gap
        ),
        # Refusing unknown flags must not also refuse the spellings GNU accepts.
        one_case(
          "end of options --",
          "TZ=UTC LC_ALL=C date -d '#{@base}' -- '+%F'; echo rc=$?"
        ),
        one_case(
          "long --date with a separate argument",
          "TZ=UTC LC_ALL=C date --date '#{@base}' '+%F'; echo rc=$?"
        ),
        one_case(
          "long --reference with a separate argument",
          "touch /tmp/jb_l_$$; TZ=UTC LC_ALL=C date --reference /tmp/jb_l_$$ '+%Y' > /dev/null; echo rc=$?; rm -f /tmp/jb_l_$$"
        ),
        one_case(
          "long --iso-8601 with a separate argument",
          "TZ=UTC LC_ALL=C date -d '#{@base}' --iso-8601 hours; echo rc=$?",
          @operand_gap
        ),
        one_case(
          "bare - operand",
          "TZ=UTC LC_ALL=C date -d '#{@base}' - '+%F'; echo rc=$?",
          @operand_gap
        ),
        one_case(
          "extra operand",
          "TZ=UTC LC_ALL=C date -d '#{@base}' extra '+%F'; echo rc=$?",
          @operand_gap
        ),
        one_case("utc flag -u", "TZ=UTC LC_ALL=C date -u -d '#{@base}' '+%F %T %Z'; echo rc=$?"),
        one_case("rfc flag -R", "TZ=UTC LC_ALL=C date -R -d '#{@base}'; echo rc=$?"),
        one_case(
          "reads -f from a file",
          "printf '%s\\n' '#{@base}' > /tmp/jb_d_$$; TZ=UTC LC_ALL=C date -f /tmp/jb_d_$$ '+%F'; echo rc=$?; rm -f /tmp/jb_d_$$",
          "-f is the BSD input-format flag here; GNU reads dates from the named file"
        )
      ]
    ])
  end

  defp date_case(name, arg, base \\ @base) do
    one_case(name, "TZ=UTC LC_ALL=C date -d '#{base}' #{arg}; echo rc=$?")
  end

  # A format case names itself, so the same format enumerated twice carries the
  # same gap marker both times.
  defp format_case(group, format, base) do
    one_case(
      "#{group} #{format}",
      "TZ=UTC LC_ALL=C date -d '#{base}' '+#{format}'; echo rc=$?",
      Map.get(@format_gaps, format)
    )
  end

  # Every case ends in `echo rc=$?` so a wrong exit code shows up as a stdout
  # difference too. The dominant failure in this corpus is exit 0 with a wrong
  # answer, and a case that only compares stdout cannot see it.
  #
  # `known_gap` rides in opts, which the digest deliberately excludes: marking a
  # gap, or closing one, must not invalidate a recording that is still correct.
  defp one_case(name, script, known_gap \\ nil) do
    test_case = %{
      "name" => "date matrix: #{name}",
      "script" => script,
      "content_hash" => Fixtures.content_hash(script)
    }

    case known_gap do
      nil -> test_case
      reason -> Map.put(test_case, "opts", %{"known_gap" => reason})
    end
  end
end
