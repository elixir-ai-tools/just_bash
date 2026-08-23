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

      mix bash_fixtures.gen printf     # write the matrix
      mix bash_fixtures printf_matrix  # record what real bash does
      mix test --only suite:printf_matrix

  Generated suites are named `<matrix>_matrix` and are safe to regenerate: the
  digest in `JustBash.Fixtures` is content-derived, so a case that did not change
  keeps its recording.

  ## Matrices

    * `date` — every strftime conversion alone, adjacently paired, and crossed
      with every field flag, locale modifier, width and compound form, plus `-I`
      granularities, `-d` input forms, and flags GNU date does not have
    * `printf` — every bash/coreutils conversion (`%s %c %d %i %u %o %x %X %f
      %e %E %g %G %a %A %%`, plus bash extras `%b` `%q`) alone at two or more
      bases, then crossed with every format flag, width, precision and `*`, plus
      `%b`/`%q` inputs that make escapes and quoting visible, and format
      recycling with excess arguments. Oils `builtin-printf.test.sh` is a
      cross-check, not this matrix. See #70 item 2.

  A list of conversions and a list of flags are each easy to write down. The
  cross of the two is where the bugs live and is what nobody enumerates by hand:
  the first version of this matrix listed both alphabets and still missed that
  `%-T` rendered "9:05:03", because it never asked a flag and a conversion in the
  same breath. Cross what you enumerate.

  ## Usage

      mix bash_fixtures.gen              # every matrix
      mix bash_fixtures.gen date         # one matrix
      mix bash_fixtures.gen printf       # one matrix
      mix bash_fixtures.gen --dry-run    # report counts, write nothing
  """

  use Mix.Task

  alias JustBash.Fixtures
  alias Mix.Tasks.BashFixtures

  @shortdoc "Generate enumerated fixture matrices"

  @matrices ["date", "printf"]

  @doc false
  def cases_for(name), do: build(name)

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

  defp resolve([]), do: @matrices

  defp resolve(names) do
    Enum.each(names, fn name ->
      unless name in @matrices, do: Mix.raise("Unknown matrix: #{name}")
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
  defp build("printf"), do: printf_cases()

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
    fixture_case("date matrix: #{name}", script, known_gap)
  end

  # ---------------------------------------------------------------------------
  # printf
  #
  # The alphabet is the conversions bash/coreutils printf documents, plus the
  # bash extras `%b` and `%q`. Flags, widths and precisions are crossed with
  # every conversion rather than sampled: which pairs mean anything is the
  # fact nobody writes down. Two or more bases per family so padding, sign,
  # precision and empty/zero are visible — one base hides half of those.
  #
  # Oils `builtin-printf.test.sh` (~63 cases) is a cross-check of shapes this
  # matrix must include, not a substitute for the cross product.
  # ---------------------------------------------------------------------------

  # Documented conversions, including `%%` as "%" so flag/width/precision
  # crosses reach it through the same path as every other specifier.
  @printf_conversions ~w(s c d i u o x X f e E g G a A b q %)

  @printf_flags [
    {"-", "left"},
    {"+", "plus"},
    {" ", "space"},
    {"0", "zero"},
    {"#", "hash"}
  ]

  # Widths chosen so they are both narrower and wider than the revealing
  # values: 7 under width 5 pads, 255 under width 5 overflows, "hi" under
  # width 1 overflows and under 5/10 pads.
  @printf_widths ~w(1 5 10)

  # Empty precision (`%.d`) is a distinct GNU/bash spelling of zero, not the
  # same as omitting the dot.
  @printf_precisions ["0", "2", "6", ""]

  # 7 vs 255: padding and hex/octal length differ. -1 vs 0: sign flags and
  # unsigned wrap become visible. Empty vs "hi": string precision and %c.
  @printf_string_bases [{"hi", "hi"}, {"empty", ""}]
  @printf_int_bases [{"seven", "7"}, {"byte", "255"}, {"neg", "-1"}, {"zero", "0"}]
  @printf_float_bases [{"pi", "3.14159"}, {"neg", "-1"}, {"zero", "0"}]
  @printf_b_bases [{"plain", "hi"}, {"escapes", "A\\tB\\n"}, {"empty", ""}]
  @printf_q_bases [{"plain", "hi"}, {"space", "a b"}, {"empty", ""}]

  # %b inputs that make escapes observable. \c must terminate. `\xff` is
  # covered by a unit test: the JSON recorder cannot carry invalid UTF-8
  # (jq --rawfile replaces the byte), so that cell would be a harness
  # artifact rather than a printf divergence.
  @printf_b_specials [
    {"tab", "A\\tB"},
    {"newline", "A\\nB"},
    {"return", "A\\rB"},
    {"backslash", "A\\\\B"},
    {"hex", "A\\x41B"},
    {"octal", "A\\101B"},
    {"hex-del", "A\\x7fB"},
    {"stop", "A\\cB"}
  ]

  # %q inputs that make shell-quoting visible. Empty, space, meta and
  # already-quoted are the four shapes that diverge first.
  @printf_q_specials [
    {"empty", ""},
    {"plain", "hi"},
    {"space", "a b"},
    {"quote", "a'b"},
    {"dollar", "$HOME"},
    {"glob", "*"},
    {"leading-dash", "-n"},
    {"dquote", "\"quoted\""}
  ]

  @printf_recycle [
    {"%s", ["a", "b", "c"]},
    {"%s %s\\n", ["a", "b", "c", "d"]},
    {"%s %s\\n", ["a", "b", "c"]},
    {"%d %d\\n", ["1", "2", "3"]},
    {"%s:%d\\n", ["a", "1", "b", "2", "c"]},
    {"%b\\n", ["a\\tb", "c"]},
    {"%q\\n", ["a b", "c"]},
    {"%s %s", ["a"]}
  ]

  @printf_percent_forms [
    {"%%", []},
    {"100%%", []},
    {"%%s", ["x"]},
    {"%s %% %s", ["a", "b"]},
    {"%%%s", ["a"]},
    {"%s%%", ["a"]}
  ]

  @printf_invalid_forms [
    {"%", []},
    {"%v", ["x"]},
    {"%s%", ["a"]},
    {"%!", ["x"]}
  ]

  # Integer spellings bash accepts and JustBash's Integer.parse/1 does not:
  # hex, octal, a quoted character, a leading plus, and leading spaces.
  @printf_int_inputs [
    {"0xff", "hex"},
    {"010", "octal"},
    {"'A", "char"},
    {"+42", "plus"},
    {"  7", "spaces"}
  ]

  # Stacked flags. The last-wins / ignore-zero-when-left rule is only
  # visible when two flags share a specifier.
  @printf_stacked [
    {"%-+5d", ["7"]},
    {"%+-5d", ["7"]},
    {"% 05d", ["7"]},
    {"%+05d", ["7"]},
    {"%#08x", ["255"]},
    {"%#08o", ["255"]},
    {"%-05d", ["7"]},
    {"%0-5d", ["7"]}
  ]

  # Gaps are assigned after recording, never by omitting a cell. Marking a
  # gap must not change the digest — the reason lives in opts.
  @unimpl_convs ~w(i u E g G a A q)

  @unimpl_conv_gap "JustBash printf does not implement this conversion; the specifier is passed through literally"
  @e_gap "JustBash %e uses Erlang ~e, which differs from bash in exponent width and default digits"
  @c_nul_gap "bash %c of an empty or missing argument emits a NUL byte; JustBash emits nothing"
  @unsigned_neg_gap "JustBash prints signed negatives for %o/%x/%X; bash treats the value as unsigned 64-bit"
  @flag_gap "JustBash printf does not implement the +, space, or # format flags"
  @star_gap "JustBash printf does not implement * for width or precision"
  @int_prec_gap "JustBash ignores precision on integer conversions; bash uses it as a minimum digit count"
  @empty_prec_gap "JustBash does not parse a precision with no digits (%.d); bash treats it as precision 0"
  @b_octal_gap "JustBash %b does not expand \\NNN octal escapes (only \\0NNN, matching echo -e)"
  @b_stop_gap "JustBash %b does not honour \\c as a terminator"
  @b_prec_gap "JustBash ignores precision on %b; bash applies it as a maximum byte count"
  @int_input_gap "JustBash Integer.parse/1 does not accept bash hex, octal, quoted-character, or leading-space operands"
  @invalid_gap "JustBash passes an invalid or incomplete specifier through at exit 0; bash prints a diagnostic"
  @no_ops_gap "JustBash printf with no operands exits 0; bash prints usage and exits 2"
  @endopt_gap "JustBash treats -- as the format string; bash consumes it as end-of-options"
  @assign_gap "JustBash printf does not implement -v; the flag is treated as the format"
  @unknown_flag_gap "JustBash absorbs an unknown flag as the format and exits 0; bash refuses it"
  @strftime_gap "JustBash printf does not implement %(fmt)T"
  @pct_mod_gap "bash rejects a flag, width or precision on %%; JustBash prints a literal percent"
  @zero_str_gap "JustBash honours 0-padding on %s/%c/%b; bash ignores the 0 flag for those conversions"
  @flag_order_gap "JustBash's format parser does not accept flags after 0 (`%0-5d`); bash left-aligns"

  defp printf_cases do
    Enum.concat([
      printf_conversion_cases(),
      printf_cross_cases(),
      printf_shape_cases(),
      printf_argument_cases()
    ])
  end

  # Each conversion on its own, at every family base.
  defp printf_conversion_cases do
    for conv <- @printf_conversions, {label, value} <- printf_bases(conv) do
      printf_case("conversion %#{conv} (#{label})", "%#{conv}", printf_args(value))
    end
  end

  # Flag × conversion, and flag+width × conversion. A flag without a width
  # is often a no-op; the width-5 cross is where left/zero/plus become
  # visible. Both are asked so a no-op is recorded rather than assumed.
  defp printf_cross_cases do
    Enum.concat([
      for {flag, flag_name} <- @printf_flags, conv <- @printf_conversions do
        printf_case(
          "flag #{flag_name} %#{conv}",
          "%#{flag}#{conv}",
          printf_revealing_args(conv)
        )
      end,
      # Width 5 is the revealing field: 7 and "hi" pad, 255 overflows. The
      # other widths are asked without flags below; repeating them here
      # would triple the cross without a new combination.
      for {flag, flag_name} <- @printf_flags, conv <- @printf_conversions do
        printf_case(
          "flag+width #{flag_name} 5 %#{conv}",
          "%#{flag}5#{conv}",
          printf_revealing_args(conv)
        )
      end
    ])
  end

  # Widths, precisions, and `*` — the finite stand-in for a runtime field.
  # `*` consumes extra arguments, so the revealing value is shifted rather
  # than dropped; a generator that forgot that would record the width as
  # the value and hide every padding bug.
  defp printf_shape_cases do
    Enum.concat([
      for width <- @printf_widths, conv <- @printf_conversions do
        printf_case("width #{width} %#{conv}", "%#{width}#{conv}", printf_revealing_args(conv))
      end,
      for prec <- @printf_precisions, conv <- @printf_conversions do
        printf_case(
          "precision #{prec_label(prec)} %#{conv}",
          "%.#{prec}#{conv}",
          printf_revealing_args(conv)
        )
      end,
      for conv <- @printf_conversions do
        printf_case(
          "width+precision 5.2 %#{conv}",
          "%5.2#{conv}",
          printf_revealing_args(conv)
        )
      end,
      for conv <- @printf_conversions do
        printf_case("star width %#{conv}", "%*#{conv}", ["5" | printf_revealing_args(conv)])
      end,
      for conv <- @printf_conversions do
        printf_case("star precision %#{conv}", "%.*#{conv}", ["2" | printf_revealing_args(conv)])
      end,
      for conv <- @printf_conversions do
        printf_case(
          "star both %#{conv}",
          "%*.*#{conv}",
          ["8", "2" | printf_revealing_args(conv)]
        )
      end,
      for {flag, flag_name} <- @printf_flags, conv <- @printf_conversions do
        printf_case(
          "flag+star #{flag_name} %#{conv}",
          "%#{flag}*#{conv}",
          ["5" | printf_revealing_args(conv)]
        )
      end
    ])
  end

  # Recycling, %b/%q inputs, missing arguments, %% sequences, refusals.
  defp printf_argument_cases do
    Enum.concat([
      for {format, args} <- @printf_recycle do
        printf_case("recycle #{inspect(format)} #{Enum.join(args, " ")}", format, args)
      end,
      for {label, value} <- @printf_b_specials do
        printf_case("%b #{label}", "%b", [value])
      end,
      for {label, value} <- @printf_q_specials do
        printf_case("%q #{label}", "%q", [value])
      end,
      for conv <- @printf_conversions do
        printf_case("missing %#{conv}", "%#{conv}", [])
      end,
      for {format, args} <- @printf_percent_forms do
        printf_case("percent #{inspect(format)}", format, args)
      end,
      for {format, args} <- @printf_invalid_forms do
        printf_case("invalid #{inspect(format)}", format, args)
      end,
      for {value, label} <- @printf_int_inputs do
        printf_case("integer input #{label}", "%d", [value])
      end,
      for {format, args} <- @printf_stacked do
        printf_case("stacked #{format}", format, args)
      end,
      [
        one_printf(
          "no operands",
          "LC_ALL=C LANG=C printf; echo rc=$?",
          @no_ops_gap
        ),
        one_printf(
          "end of options --",
          "LC_ALL=C LANG=C printf -- '%s' -n; echo rc=$?",
          @endopt_gap
        ),
        one_printf(
          "assign -v",
          "LC_ALL=C LANG=C printf -v x '%s' hi; echo \"$x\"; echo rc=$?",
          @assign_gap
        ),
        one_printf(
          "unknown flag -Z",
          "LC_ALL=C LANG=C printf -Z '%s' hi; echo rc=$?",
          @unknown_flag_gap
        ),
        one_printf(
          "strftime %(%Y)T epoch",
          "LC_ALL=C LANG=C TZ=UTC printf '%(%Y-%m-%d)T' 0; echo rc=$?",
          @strftime_gap
        ),
        one_printf(
          "strftime %(%F)T unix",
          "LC_ALL=C LANG=C TZ=UTC printf '%(%F)T' 1718458200; echo rc=$?",
          @strftime_gap
        )
      ]
    ])
  end

  defp printf_bases(conv) when conv in ~w(s c), do: @printf_string_bases
  defp printf_bases(conv) when conv in ~w(d i), do: @printf_int_bases
  defp printf_bases(conv) when conv in ~w(u o x X), do: @printf_int_bases
  defp printf_bases(conv) when conv in ~w(f e E g G a A), do: @printf_float_bases
  defp printf_bases("b"), do: @printf_b_bases
  defp printf_bases("q"), do: @printf_q_bases
  defp printf_bases("%"), do: [{"literal", nil}]

  # One revealing value per conversion so a flag/width run is not hidden by
  # a value that already fills the field. 7 (not 15) for signed; 255 for
  # hex/octal; empty-capable strings stay "hi" so %c and precision truncate.
  defp printf_revealing("s"), do: "hi"
  defp printf_revealing("c"), do: "hi"
  defp printf_revealing(conv) when conv in ~w(d i), do: "7"
  defp printf_revealing(conv) when conv in ~w(u o x X), do: "255"
  defp printf_revealing(conv) when conv in ~w(f e E g G a A), do: "3.14159"
  defp printf_revealing("b"), do: "A\\tB\\n"
  defp printf_revealing("q"), do: "a b"
  defp printf_revealing("%"), do: nil

  defp printf_revealing_args(conv), do: printf_args(printf_revealing(conv))

  defp printf_args(nil), do: []
  defp printf_args(value), do: [value]

  defp prec_label(""), do: "empty"
  defp prec_label(prec), do: prec

  defp printf_case(name, format, args) do
    one_printf(name, printf_script(format, args), printf_gap(name, format, args))
  end

  defp printf_script(format, args) do
    quoted = Enum.map_join([format | args], " ", &sh_single/1)
    "LC_ALL=C LANG=C printf #{quoted}; echo rc=$?"
  end

  # Single-quote an operand so spaces, stars and leading dashes stay data.
  # Formats never contain a single quote, so the replace is defensive.
  defp sh_single(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp one_printf(name, script, known_gap) do
    fixture_case("printf matrix: #{name}", script, known_gap)
  end

  defp printf_gap(name, format, args) do
    case special_printf_gap(name, format) do
      :none ->
        case named_conv(name) do
          nil -> nil
          conv -> gap_for_conv_cell(name, format, args, conv)
        end

      gap ->
        gap
    end
  end

  defp special_printf_gap(name, format) do
    cond do
      String.starts_with?(name, "percent ") -> nil
      String.starts_with?(name, "invalid ") -> @invalid_gap
      int_input_gap?(name) -> @int_input_gap
      name == "%b octal" -> @b_octal_gap
      name == "%b stop" -> @b_stop_gap
      q_gap?(name, format) -> @unimpl_conv_gap
      star_gap?(name) -> @star_gap
      true -> stacked_gap(name)
    end
  end

  defp int_input_gap?(name) do
    name in [
      "integer input hex",
      "integer input octal",
      "integer input char",
      "integer input spaces"
    ]
  end

  defp q_gap?(name, format) do
    String.starts_with?(name, "%q ") or
      (String.starts_with?(name, "recycle ") and String.contains?(format, "%q"))
  end

  defp star_gap?(name) do
    String.starts_with?(name, "star ") or String.starts_with?(name, "flag+star ")
  end

  defp stacked_gap("stacked %0-5d"), do: @flag_order_gap
  defp stacked_gap("stacked %-05d"), do: nil
  defp stacked_gap("stacked " <> _), do: @flag_gap
  defp stacked_gap(_), do: :none

  defp named_conv(name) do
    case Regex.run(~r/%([a-zA-Z%])(?:\s|\(|$)/, name) do
      [_, conv] -> conv
      _ -> nil
    end
  end

  defp gap_for_conv_cell(_name, _format, _args, conv) when conv in @unimpl_convs do
    @unimpl_conv_gap
  end

  defp gap_for_conv_cell(name, format, args, conv) do
    cond do
      conv == "%" and percent_modified?(name, format) -> @pct_mod_gap
      conv == "e" -> @e_gap
      conv == "c" and args in [[], [""]] -> @c_nul_gap
      conv in ~w(o x X) and args == ["-1"] -> @unsigned_neg_gap
      true -> gap_for_parsed_conv(name, format, conv)
    end
  end

  defp gap_for_parsed_conv(name, format, conv) do
    cond do
      empty_precision?(format) -> @empty_prec_gap
      conv == "b" and b_precision_truncates?(name) -> @b_prec_gap
      integer_precision_visible?(name, conv) -> @int_prec_gap
      has_unimpl_flag?(format) -> @flag_gap
      zero_pad_string?(format, conv) -> @zero_str_gap
      true -> nil
    end
  end

  defp percent_modified?(name, format) do
    String.contains?(name, "width ") or
      String.contains?(name, "precision ") or
      String.contains?(name, "flag ") or
      format not in ["%%"]
  end

  defp empty_precision?(format),
    do: String.contains?(format, "%.") and not String.match?(format, ~r/%\.\d/)

  # Precision is a minimum digit count. It only changes the output when it
  # is longer than the revealing value: 7 is one digit, 255 is 3 octal / 2 hex.
  defp integer_precision_visible?(name, conv) do
    cond do
      conv == "d" and name in ["precision 2 %d", "precision 6 %d", "width+precision 5.2 %d"] ->
        true

      conv in ~w(o x X) and String.starts_with?(name, "precision 6 ") ->
        true

      true ->
        false
    end
  end

  defp b_precision_truncates?(name) do
    name in ["precision 0 %b", "precision 2 %b", "width+precision 5.2 %b"]
  end

  defp has_unimpl_flag?(format) do
    String.contains?(format, "+") or String.contains?(format, "#") or
      String.contains?(format, "% ")
  end

  # `%05s` is a zero flag; `%10s` and `%.0s` only happen to contain a 0.
  defp zero_pad_string?(format, conv) do
    conv in ~w(s c b) and String.match?(format, ~r/%-?0\d/)
  end

  defp fixture_case(name, script, known_gap) do
    test_case = %{
      "name" => name,
      "script" => script,
      "content_hash" => Fixtures.content_hash(script)
    }

    case known_gap do
      nil -> test_case
      reason -> Map.put(test_case, "opts", %{"known_gap" => reason})
    end
  end
end
