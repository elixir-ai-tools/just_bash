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

      mix bash_fixtures.gen test       # write the matrix
      mix bash_fixtures test_matrix    # record what real bash does
      mix test --only suite:test_matrix

      mix bash_fixtures.gen varop      # write the matrix
      mix bash_fixtures varop_matrix   # record what real bash does
      mix test --only suite:varop_matrix

      mix bash_fixtures.gen flags      # write the matrix
      mix bash_fixtures flags_matrix   # record what real bash does
      mix test --only suite:flags_matrix

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
    * `test` — every POSIX/`[` operator (`-b -c -d -e -f -g -h -k -L -n -p
      -r -S -s -t -u -w -x -z`, `=` `==` `!=` `<` `>`, `-eq -ne -lt -le -gt
      -ge`, `-nt -ot -ef`, `-a -o`, `!`, plus bash extras `-G -O -N`) crossed
      with revealing operand shapes for that operator — file/dir/missing/empty/
      symlink/dangling for file tests, empty/nonempty/"0" for `-z`/`-n`, equal/
      unequal/10-vs-9 for string and integer compares. Both `test` and `[` for
      a representative subset so they cannot drift; the full operator list is
      on `test`. This is not the item-3 filesystem-shape × command cube. See
      #70 item 2.
    * `varop` — every POSIX/bash `${var op word}` form (`-` `:-` `=` `:=` `+`
      `:+` `?` `:?`, `#` `##` `%` `%%`, `${#var}`, `${var:offset}`,
      `${var:offset:len}`, `${var/pat/rep}`, `${var//pat/rep}`) crossed with
      unset / set-empty / set-nonempty, and with a nonempty vs empty word
      where that changes the answer. Two nonempty bases (`foo` vs `foobar`,
      plus `foofoo` where shortest vs longest or first vs all would otherwise
      hide) so one value cannot hide the bug. Suite `varop_matrix`. See #70
      item 2.
    * `flags` — `cmd --jb-not-a-flag` and `cmd -Z` for every name in
      `Commands.Registry`. The default assertion is non-zero exit and
      usage-bearing stderr (never exit 0). Commands that legitimately treat
      the token as an operand (`echo`), accept GNU `-Z` (SELinux, `diff -Z`,
      `grep -Z`, `curl -Z`), or have no GNU twin (`markdown`/`md`) are still
      generated and named with a reason — never silently omitted. Suite
      `flags_matrix`. This is the registry-wide unknown-flag probe from #70
      item 2; `unknown_flags_test.exs` keeps the FlagParser unit tests from
      #68 rather than a second classification table.

  A list of conversions and a list of flags are each easy to write down. The
  cross of the two is where the bugs live and is what nobody enumerates by hand:
  the first version of this matrix listed both alphabets and still missed that
  `%-T` rendered "9:05:03", because it never asked a flag and a conversion in the
  same breath. Cross what you enumerate.

  ## Usage

      mix bash_fixtures.gen              # every matrix
      mix bash_fixtures.gen date         # one matrix
      mix bash_fixtures.gen printf       # one matrix
      mix bash_fixtures.gen test         # one matrix
      mix bash_fixtures.gen varop        # one matrix
      mix bash_fixtures.gen flags        # one matrix
      mix bash_fixtures.gen --dry-run    # report counts, write nothing
  """

  use Mix.Task

  alias JustBash.Commands.Registry
  alias JustBash.Fixtures
  alias Mix.Tasks.BashFixtures

  @shortdoc "Generate enumerated fixture matrices"

  @matrices ["date", "printf", "test", "varop", "flags"]

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
  defp build("test"), do: test_cases()
  defp build("varop"), do: varop_cases()
  defp build("flags"), do: flags_cases()

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

  # ---------------------------------------------------------------------------
  # test / [
  #
  # The alphabet is the POSIX `test`/`[` operators plus the bash extras this
  # shell already claims (`==`, `<`, `>`, `-G`, `-O`, `-N`). Each operator is
  # crossed with revealing operand shapes for *that* operator — not the item-3
  # filesystem-shape × command cube. Two or more bases per family so
  # false-vs-missing, empty-vs-nonempty, and 10-vs-9 cannot hide behind a
  # single value that already fills the field.
  #
  # The full operator list is asked of `test`. A representative subset is
  # asked of both `test` and `[` so the two spellings cannot drift.
  #
  # Gaps are assigned after recording, never by omitting a cell. Marking a
  # gap must not change the digest — the reason lives in opts.
  # ---------------------------------------------------------------------------

  # POSIX file/string unary operators, then bash extras. Enumerated rather
  # than curated: which of these JustBash implements is exactly the fact
  # nobody writes down.
  @test_file_unary ~w(-e -f -d -L -h -s -r -w -x)
  @test_type_unary ~w(-b -c -p -S)
  @test_mode_unary ~w(-u -g -k -G -O -N)
  @test_string_unary ~w(-z -n)
  @test_string_binary ~w(= == != < >)
  @test_int_binary ~w(-eq -ne -lt -le -gt -ge)

  # Shapes that make file operators distinguishable. A regular file and a
  # missing path are both "not a directory"; only asking both shows whether
  # `-d` is false-for-file or false-for-absent. Symlink vs dangling is the
  # same pair for `-e`/`-L`/`-h`.
  @test_file_shapes [
    {:regular, "file"},
    {:empty, "empty"},
    {:directory, "dir"},
    {:missing, "missing"},
    {:symlink, "link"},
    {:dangling, "dang"}
  ]

  # -z/-n: empty vs nonempty is the definition. "0" is nonempty (unlike
  # arithmetic); a space is nonempty too. One of those two hides if the
  # implementation trims or truthiness-coerces.
  @test_string_unary_bases [
    {"empty", ""},
    {"hi", "hi"},
    {"zero", "0"},
    {"space", " "}
  ]

  # One-arg `test STRING` is implicit `-n`. Operators-as-operands (`=`, `!`)
  # are the lookahead cases Oils pins.
  @test_one_arg_bases [
    {"empty", ""},
    {"hi", "hi"},
    {"zero", "0"},
    {"dash", "-"},
    {"equals", "="},
    {"bang", "!"}
  ]

  # Two families so one pair cannot hide the operator: equal vs unequal,
  # and 10-vs-9 where string order and numeric order disagree.
  @test_string_binary_pairs [
    {"equal", "hi", "hi"},
    {"unequal", "a", "b"},
    {"empty-empty", "", ""},
    {"empty-hi", "", "hi"},
    {"case", "A", "a"},
    {"digits", "10", "9"}
  ]

  # 0/1 and -1/0 make sign and zero visible. 10/9 is the order that `-lt`
  # and `<` disagree on. Non-numeric and `08` are the Integer.parse traps.
  @test_int_binary_pairs [
    {"zeros", "0", "0"},
    {"zero-one", "0", "1"},
    {"neg-zero", "-1", "0"},
    {"equal", "7", "7"},
    {"order", "10", "9"},
    {"non-numeric", "a", "b"},
    {"octal-looking", "08", "8"},
    {"spaces", " 7", "7"}
  ]

  # `[` is asked only on this subset so the two commands cannot drift.
  # The full operator list stays on `test`.
  @test_bracket_file_ops ~w(-e -f -d -L -s)
  @test_bracket_string_unary [{"-z", "empty", ""}, {"-n", "hi", "hi"}]
  @test_bracket_string_binary [{"=", "equal", "hi", "hi"}, {"!=", "unequal", "a", "b"}]
  @test_bracket_int_binary [{"-eq", "zeros", "0", "0"}, {"-lt", "order", "10", "9"}]

  # Gaps named after the divergence, not the operator, so a later fix of
  # `-x` does not keep the integer-parse cells marked.
  @unimpl_unary_gap "JustBash test treats this unary operator as unknown and returns 1; bash implements it"
  @unimpl_file_cmp_gap "JustBash test does not implement -nt/-ot/-ef; bash compares mtimes or identity"
  @perm_gap "JustBash -r/-w/-x are existence checks; bash tests the corresponding permission bit"
  @devnull_file_gap "JustBash types /dev/null as a regular file; bash reports it as a character device"
  @dir_size_gap "JustBash reports directory size 0 so test -s dir is false; bash directories have nonzero size"
  @int_parse_gap "JustBash Integer.parse/1 does not accept the integer spelling bash test accepts"
  @int_stderr_gap "JustBash test returns 2 on a non-integer with no diagnostic; bash writes to stderr"
  @arity_gap "JustBash test returns 1 for extra or unparsed arguments; bash exits 2 and diagnoses"
  @unknown_op_gap "JustBash test returns 1 for an unknown operator; bash exits 2 and diagnoses"
  @slash_file_gap "JustBash treats a trailing slash on a regular file as the file; bash requires a directory"
  @bracket_syntax_gap "JustBash [ without a closing ] still evaluates the expression; bash exits 2"
  @group_gap "JustBash test does not implement ( ) grouping"
  @andor_nary_gap "JustBash test does not implement 4+ argument -a/-o as expression AND/OR"
  @unary_a_gap "JustBash does not implement unary -a as a synonym of -e"
  @setup_or_op_gap "JustBash cannot construct this operand shape (fifo, setuid, sticky, dated mtime) and/or does not implement the operator"

  defp test_cases do
    Enum.concat([
      test_file_unary_cases(),
      test_type_mode_cases(),
      test_string_cases(),
      test_int_cases(),
      test_file_binary_cases(),
      test_logic_cases(),
      test_syntax_cases(),
      test_bracket_cases()
    ])
  end

  # File unary × revealing shapes, on `test` only. Permission bits get an
  # extra chmod'd base so `-x` on a 644 file is not the same cell as `-x`
  # on a missing file.
  defp test_file_unary_cases do
    Enum.concat([
      for op <- @test_file_unary, {shape, path} <- @test_file_shapes do
        test_file_case("test #{op} (#{shape})", "test", [op, {:path, path}], shape)
      end,
      [
        test_file_case("test -x (executable)", "test", ["-x", {:path, "exe"}], :executable),
        test_file_case("test -r (unreadable)", "test", ["-r", {:path, "noread"}], :unreadable),
        test_file_case("test -w (unreadable)", "test", ["-w", {:path, "noread"}], :unreadable),
        test_file_case("test -x (unreadable)", "test", ["-x", {:path, "noread"}], :unreadable),
        test_file_case("test -e (enotdir)", "test", ["-e", {:path, "file/x"}], :enotdir),
        test_file_case(
          "test -d (trailing-slash dir)",
          "test",
          ["-d", {:path, "dir/"}],
          :directory
        ),
        test_file_case(
          "test -f (trailing-slash file)",
          "test",
          ["-f", {:path, "file/"}],
          :regular
        ),
        test_abs_case("test -e (/dev/null)", "test", ["-e", "/dev/null"]),
        test_abs_case("test -f (/dev/null)", "test", ["-f", "/dev/null"]),
        test_abs_case("test -c (/dev/null)", "test", ["-c", "/dev/null"]),
        test_abs_case("test -s (/dev/null)", "test", ["-s", "/dev/null"])
      ]
    ])
  end

  # Type and mode operators. The matching type is the cell that would
  # hide behind "false on a regular file" if we never asked it.
  defp test_type_mode_cases do
    Enum.concat([
      for op <- @test_type_unary, {shape, path} <- [{:regular, "file"}, {:missing, "missing"}] do
        test_file_case("test #{op} (#{shape})", "test", [op, {:path, path}], shape)
      end,
      [
        test_file_case("test -p (fifo)", "test", ["-p", {:path, "fifo"}], :fifo)
      ],
      for op <- @test_mode_unary do
        test_file_case("test #{op} (regular)", "test", [op, {:path, "file"}], :regular)
      end,
      [
        test_file_case("test -u (setuid)", "test", ["-u", {:path, "suid"}], :setuid),
        test_file_case("test -g (setgid)", "test", ["-g", {:path, "sgid"}], :setgid),
        test_file_case("test -k (sticky)", "test", ["-k", {:path, "sticky"}], :sticky),
        test_file_case("test -u (missing)", "test", ["-u", {:path, "missing"}], :missing),
        test_file_case("test -O (missing)", "test", ["-O", {:path, "missing"}], :missing)
      ],
      for fd <- ["0", "1", "2", "99"] do
        test_plain_case("test -t (fd #{fd})", "test", ["-t", fd])
      end,
      [
        test_plain_case("test -t (invalid)", "test", ["-t", "invalid"]),
        test_plain_case("test -t (one-arg)", "test", ["-t"])
      ]
    ])
  end

  defp test_string_cases do
    Enum.concat([
      for op <- @test_string_unary, {label, value} <- @test_string_unary_bases do
        test_plain_case("test #{op} (#{label})", "test", [op, value])
      end,
      for {label, value} <- @test_one_arg_bases do
        test_plain_case("test one-arg (#{label})", "test", [value])
      end,
      for op <- @test_string_binary, {label, left, right} <- @test_string_binary_pairs do
        test_plain_case("test #{op} (#{label})", "test", [left, op, right])
      end
    ])
  end

  defp test_int_cases do
    for op <- @test_int_binary, {label, left, right} <- @test_int_binary_pairs do
      test_plain_case("test #{op} (#{label})", "test", [left, op, right])
    end
  end

  # File compares need two operands with a known relationship. `-nt` of
  # older-vs-newer is false; newer-vs-older is the cell that would match
  # "unimplemented returns 1" if we only asked the false side.
  defp test_file_binary_cases do
    [
      test_file_case(
        "test -nt (older-newer)",
        "test",
        [{:path, "old"}, "-nt", {:path, "new"}],
        :older_newer
      ),
      test_file_case(
        "test -nt (newer-older)",
        "test",
        [{:path, "new"}, "-nt", {:path, "old"}],
        :older_newer
      ),
      test_file_case(
        "test -ot (older-newer)",
        "test",
        [{:path, "old"}, "-ot", {:path, "new"}],
        :older_newer
      ),
      test_file_case(
        "test -ot (newer-older)",
        "test",
        [{:path, "new"}, "-ot", {:path, "old"}],
        :older_newer
      ),
      test_file_case(
        "test -nt (same)",
        "test",
        [{:path, "file"}, "-nt", {:path, "file"}],
        :regular
      ),
      test_file_case(
        "test -ot (same)",
        "test",
        [{:path, "file"}, "-ot", {:path, "file"}],
        :regular
      ),
      test_file_case(
        "test -ef (same-path)",
        "test",
        [{:path, "file"}, "-ef", {:path, "file"}],
        :regular
      ),
      test_file_case(
        "test -ef (hardlink)",
        "test",
        [{:path, "f"}, "-ef", {:path, "hard"}],
        :hardlink
      ),
      test_file_case(
        "test -ef (distinct)",
        "test",
        [{:path, "a"}, "-ef", {:path, "b"}],
        :two_files
      ),
      test_file_case(
        "test -nt (missing-file)",
        "test",
        [{:path, "missing"}, "-nt", {:path, "file"}],
        :regular
      ),
      test_file_case(
        "test -ef (missing-file)",
        "test",
        [{:path, "missing"}, "-ef", {:path, "file"}],
        :regular
      )
    ]
  end

  defp test_logic_cases do
    Enum.concat([
      [
        test_plain_case("test -a (hi-hi)", "test", ["hi", "-a", "hi"]),
        test_plain_case("test -a (hi-empty)", "test", ["hi", "-a", ""]),
        test_plain_case("test -o (empty-hi)", "test", ["", "-o", "hi"]),
        test_plain_case("test -o (empty-empty)", "test", ["", "-o", ""]),
        test_file_case("test unary -a (regular)", "test", ["-a", {:path, "file"}], :regular),
        test_file_case("test unary -a (missing)", "test", ["-a", {:path, "missing"}], :missing),
        test_file_case(
          "test -a (file-and-dir)",
          "test",
          ["-f", {:path, "file"}, "-a", "-d", {:path, "dir"}],
          :file_and_dir
        ),
        test_file_case(
          "test -a (missing-and-dir)",
          "test",
          ["-f", {:path, "missing"}, "-a", "-d", {:path, "dir"}],
          :directory
        ),
        test_plain_case("test ! (empty)", "test", ["!", ""]),
        test_plain_case("test ! (hi)", "test", ["!", "hi"]),
        test_plain_case("test ! -z (empty)", "test", ["!", "-z", ""]),
        test_plain_case("test ! -z (hi)", "test", ["!", "-z", "hi"]),
        test_file_case("test ! -f (missing)", "test", ["!", "-f", {:path, "missing"}], :missing),
        test_file_case("test ! -f (regular)", "test", ["!", "-f", {:path, "file"}], :regular),
        test_plain_case("test ! = (equal)", "test", ["!", "a", "=", "a"]),
        test_plain_case("test ! = (unequal)", "test", ["!", "a", "=", "b"]),
        test_plain_case("test group (hi)", "test", ["(", "hi", ")"]),
        test_plain_case("test group (-z empty)", "test", ["(", "-z", "", ")"]),
        test_plain_case("test group (= equal)", "test", ["(", "a", "=", "a", ")"])
      ]
    ])
  end

  defp test_syntax_cases do
    [
      test_plain_case("test no-args", "test", []),
      test_plain_case("test extra-args", "test", ["-n", "x", "y"]),
      test_plain_case("test unknown unary", "test", ["-Z", "x"]),
      test_plain_case("test unknown binary", "test", ["a", "-xx", "b"]),
      test_plain_case("test too-many", "test", ["a", "=", "a", "=", "a"]),
      one_test(
        "[ no-args",
        "LC_ALL=C LANG=C [; echo rc=$?",
        test_gap("[ no-args")
      ),
      one_test(
        "[ empty",
        "LC_ALL=C LANG=C [ ]; echo rc=$?",
        test_gap("[ empty")
      ),
      one_test(
        "[ missing-closer",
        "LC_ALL=C LANG=C [ -n x; echo rc=$?",
        test_gap("[ missing-closer")
      ),
      one_test(
        "[ extra-after-closer",
        "LC_ALL=C LANG=C [ -n x ] y; echo rc=$?",
        test_gap("[ extra-after-closer")
      )
    ]
  end

  # Representative `[` cells, plus the matching `test` cells already
  # enumerated above for the same expressions. Drift between the two is
  # a harness failure, not a known gap.
  defp test_bracket_cases do
    Enum.concat([
      for op <- @test_bracket_file_ops, {shape, path} <- bracket_file_shapes(op) do
        test_file_case("[ #{op} (#{shape})", "[", [op, {:path, path}], shape)
      end,
      for {op, label, value} <- @test_bracket_string_unary do
        test_plain_case("[ #{op} (#{label})", "[", [op, value])
      end,
      for {label, value} <- [{"empty", ""}, {"hi", "hi"}] do
        test_plain_case("[ one-arg (#{label})", "[", [value])
      end,
      for {op, label, left, right} <- @test_bracket_string_binary do
        test_plain_case("[ #{op} (#{label})", "[", [left, op, right])
      end,
      for {op, label, left, right} <- @test_bracket_int_binary do
        test_plain_case("[ #{op} (#{label})", "[", [left, op, right])
      end,
      [
        test_plain_case("[ ! -z (empty)", "[", ["!", "-z", ""]),
        test_plain_case("[ -a (hi-hi)", "[", ["hi", "-a", "hi"]),
        test_file_case("[ -L (dangling)", "[", ["-L", {:path, "dang"}], :dangling)
      ]
    ])
  end

  defp bracket_file_shapes("-L"), do: [{:symlink, "link"}, {:regular, "file"}]
  defp bracket_file_shapes("-s"), do: [{:empty, "empty"}, {:regular, "file"}]

  defp bracket_file_shapes("-f"),
    do: [{:regular, "file"}, {:directory, "dir"}, {:missing, "missing"}]

  defp bracket_file_shapes("-d"),
    do: [{:directory, "dir"}, {:regular, "file"}, {:missing, "missing"}]

  defp bracket_file_shapes("-e"),
    do: [{:regular, "file"}, {:missing, "missing"}, {:dangling, "dang"}]

  defp test_file_case(name, cmd, args, shape) do
    one_test(name, setup_script(name, cmd, args, shape), test_gap(name))
  end

  defp test_abs_case(name, cmd, args) do
    one_test(name, expr_script(cmd, args), test_gap(name))
  end

  defp test_plain_case(name, cmd, args) do
    one_test(name, expr_script(cmd, args), test_gap(name))
  end

  defp expr_script(cmd, args) do
    "LC_ALL=C LANG=C #{format_cmd(cmd, args)}; echo rc=$?"
  end

  defp setup_script(name, cmd, args, shape) do
    slug = slugify(name)
    setup = shape_setup(shape)

    "D=/tmp/jb_t_#{slug}; mkdir -p \"$D\"; #{setup}; LC_ALL=C LANG=C #{format_cmd(cmd, args)}; echo rc=$?"
  end

  defp format_cmd("test", args), do: String.trim("test #{format_args(args)}")
  defp format_cmd("[", args), do: String.trim("[ #{format_args(args)} ]")

  defp format_args(args), do: Enum.map_join(args, " ", &format_arg/1)

  defp format_arg({:path, rel}), do: "\"$D/#{rel}\""
  defp format_arg(value) when is_binary(value), do: sh_single(value)

  defp slugify(name) do
    name
    |> String.replace("[", "br")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 60)
  end

  defp shape_setup(:regular), do: "printf 'hello\\n' > \"$D/file\""
  defp shape_setup(:empty), do: "printf '' > \"$D/empty\""
  defp shape_setup(:directory), do: "mkdir -p \"$D/dir\""
  defp shape_setup(:missing), do: ":"

  defp shape_setup(:symlink),
    do: "printf 'hello\\n' > \"$D/target\"; ln -s \"$D/target\" \"$D/link\""

  defp shape_setup(:dangling), do: "ln -s \"$D/nope\" \"$D/dang\""
  defp shape_setup(:executable), do: "printf 'echo hi\\n' > \"$D/exe\"; chmod +x \"$D/exe\""
  defp shape_setup(:unreadable), do: "printf 'x\\n' > \"$D/noread\"; chmod 000 \"$D/noread\""
  defp shape_setup(:fifo), do: "mkfifo \"$D/fifo\" 2>/dev/null"

  defp shape_setup(:older_newer),
    do:
      "touch -d '2017-12-31' \"$D/old\" 2>/dev/null; touch -d '2018-01-01' \"$D/new\" 2>/dev/null"

  defp shape_setup(:hardlink), do: "printf 'x\\n' > \"$D/f\"; ln \"$D/f\" \"$D/hard\""
  defp shape_setup(:two_files), do: "printf 'a\\n' > \"$D/a\"; printf 'b\\n' > \"$D/b\""
  defp shape_setup(:setuid), do: "printf 'x\\n' > \"$D/suid\"; chmod u+s \"$D/suid\""
  defp shape_setup(:setgid), do: "printf 'x\\n' > \"$D/sgid\"; chmod g+s \"$D/sgid\""
  defp shape_setup(:sticky), do: "mkdir -p \"$D/sticky\"; chmod +t \"$D/sticky\""
  defp shape_setup(:enotdir), do: "printf 'x\\n' > \"$D/file\""
  defp shape_setup(:file_and_dir), do: "printf 'hello\\n' > \"$D/file\"; mkdir -p \"$D/dir\""

  defp one_test(name, script, known_gap) do
    fixture_case("test matrix: #{name}", script, known_gap)
  end

  # Assigned after recording. A cell that matches is left unmarked even
  # when the operator is unimplemented — returning 1 on a non-pipe is
  # indistinguishable from a correct `-p`, and marking it would invert a
  # passing assertion. The revealing shape carries the gap instead.
  defp test_gap(name) do
    case file_shape_gap(name) do
      :none -> operator_gap(name)
      gap -> gap
    end
  end

  defp file_shape_gap(name) do
    cond do
      name in ["test -c (/dev/null)", "test -f (/dev/null)"] -> @devnull_file_gap
      name == "test -s (directory)" -> @dir_size_gap
      name == "test -f (trailing-slash file)" -> @slash_file_gap
      setup_shape_gap?(name) -> @setup_or_op_gap
      file_cmp_name?(name) -> file_cmp_gap(name)
      true -> :none
    end
  end

  defp setup_shape_gap?(name) do
    name in ["test -p (fifo)", "test -u (setuid)", "test -g (setgid)", "test -k (sticky)"]
  end

  defp file_cmp_name?(name) do
    String.contains?(name, " -nt ") or String.contains?(name, " -ot ") or
      String.contains?(name, " -ef ")
  end

  defp file_cmp_gap(name) do
    if name in [
         "test -nt (newer-older)",
         "test -ot (older-newer)",
         "test -ef (same-path)",
         "test -ef (hardlink)"
       ] do
      @unimpl_file_cmp_gap
    else
      :none
    end
  end

  defp operator_gap(name) do
    cond do
      perm_gap?(name) -> @perm_gap
      name == "test unary -a (regular)" -> @unary_a_gap
      name == "test -a (file-and-dir)" -> @andor_nary_gap
      String.starts_with?(name, "test group ") -> @group_gap
      true -> syntax_gap(name)
    end
  end

  defp perm_gap?(name) do
    name in [
      "test -x (regular)",
      "test -x (empty)",
      "test -x (unreadable)",
      "test -x (symlink)",
      "test -r (unreadable)",
      "test -w (unreadable)"
    ]
  end

  defp syntax_gap(name) do
    cond do
      name in ["[ no-args", "[ missing-closer", "[ extra-after-closer"] -> @bracket_syntax_gap
      name in ["test extra-args", "test too-many"] -> @arity_gap
      name in ["test unknown unary", "test unknown binary"] -> @unknown_op_gap
      int_spelling_gap?(name) -> int_spelling_reason(name)
      name in ["test -O (regular)", "test -G (regular)"] -> @unimpl_unary_gap
      true -> nil
    end
  end

  defp int_spelling_gap?(name) do
    String.contains?(name, "(non-numeric)") or String.contains?(name, "(spaces)")
  end

  defp int_spelling_reason(name) do
    if String.contains?(name, "(non-numeric)") do
      @int_stderr_gap
    else
      @int_parse_gap
    end
  end

  # ---------------------------------------------------------------------------
  # varop — `${var op word}` parameter expansion
  #
  # The alphabet is the POSIX/bash forms JustBash implements: defaults and
  # alternatives (`-` `:-` `=` `:=` `+` `:+` `?` `:?`), length (`${#var}`),
  # prefix/suffix removal (`#` `##` `%` `%%`), substring (`${var:offset}` /
  # `${var:offset:len}`), and pattern replacement (`/` `//`). Each operator
  # is crossed with unset / set-empty / set-nonempty rather than sampled:
  # `-` vs `:-` is invisible unless empty and unset are both asked, and
  # `+` vs `:+` is the same fact from the other side.
  #
  # Two nonempty bases — `foo` and `foobar` — so a substring, prefix or
  # suffix that happens to agree on one value cannot hide. `foofoo` is the
  # extra base for `#`/`##`/`%`/`%%` and `/`/`//`, where shortest vs
  # longest and first vs all are otherwise the same cell.
  #
  # Every expansion is double-quoted (`"${v-word}"`) so the script is what
  # bash sees: empty results stay empty, and `*` in a pattern is not a
  # pathname. `set +u` is explicit except for the nounset cells, which
  # use `set -u` so we record which operators are unset-safe (`-` `:-`
  # and the other word-ops) and which still fire (`${#v}`, substring,
  # removal, replacement).
  # ---------------------------------------------------------------------------

  # Word-taking operators. The colon forms treat empty as unset; the
  # non-colon forms do not. That distinction is the whole reason to
  # enumerate empty and unset separately.
  @varop_word_ops [
    {"-", "default-unset"},
    {":-", "default-null"},
    {"=", "assign-unset"},
    {":=", "assign-null"},
    {"+", "alt-set"},
    {":+", "alt-null"},
    {"?", "error-unset"},
    {":?", "error-null"}
  ]

  # Empty vs nonempty word. For `-`/`:-`/`=`/`:=` the empty word is the
  # cell that would hide behind "uses the default" if we only asked
  # `word`. For `+`/`:+` the nonempty word is what the expansion *is*.
  # For `?`/`:?` the word is the diagnostic (or bash's "parameter null
  # or not set" when it is empty).
  @varop_words [{"word", "word"}, {"empty", ""}]

  @varop_states [
    {"unset", :unset},
    {"empty", :empty},
    {"foo", {:set, "foo"}},
    {"foobar", {:set, "foobar"}}
  ]

  # Prefix/suffix patterns. `foo` matches both nonempty bases as a
  # prefix and only `foo` as a suffix; `bar` matches only `foobar` as a
  # suffix. `f*` / `*r` / `*` are where `#` vs `##` and `%` vs `%%`
  # disagree; the empty pattern is the no-op that a generator which
  # required a word would omit.
  @varop_prefix_pats ["foo", "f*", "bar", "*", ""]
  @varop_suffix_pats ["foo", "bar", "*r", "*", ""]

  # Offsets and lengths that distinguish `foo` from `foobar`: `:3` is
  # empty vs `bar`, `:1:3` is `oo` vs `oob`, `: -1` is `o` vs `r`.
  # `: -N` needs the space so bash does not parse it as `:-`. `::2` is
  # the empty-offset spelling; `:0:-1` is a negative length.
  @varop_slices [
    ":0",
    ":1",
    ":3",
    ":6",
    ": -1",
    ": -3",
    ":0:0",
    ":1:2",
    ":1:3",
    ":3:2",
    ": -2:1",
    ":0:-1",
    "::2"
  ]

  # First-vs-all replacements. `o` occurs twice in both nonempty bases,
  # so `/` and `//` disagree; `foo`/`bar` are the literal match and
  # miss; empty replacement is deletion.
  @varop_replaces [
    {"o", "X"},
    {"o", ""},
    {"foo", "X"},
    {"bar", "X"}
  ]

  defp varop_cases do
    Enum.concat([
      varop_word_cases(),
      varop_nounset_cases(),
      varop_length_cases(),
      varop_slice_cases(),
      varop_remove_cases(),
      varop_replace_cases()
    ])
  end

  # 8 operators × 2 words × 4 states. The colon/non-colon pair is only
  # visible when empty and unset are both present; the two nonempty
  # bases are only visible when the operator returns the value (`-` on
  # a set var, or `+` wrongly returning it).
  defp varop_word_cases do
    extra_default_one =
      for {label, state} <- @varop_states do
        # `${v:-1}` is default-null with word `1`, not substring. Asked
        # next to `${v: -1}` so a parser that drops the colon/space
        # distinction cannot hide behind `word`.
        varop_case("${v:-1} (#{label})", varop_setup(state), "${v:-1}", [])
      end

    word_cross =
      for {op, _kind} <- @varop_word_ops,
          {word_label, word} <- @varop_words,
          {state_label, state} <- @varop_states do
        expansion = "${v#{op}#{word}}"
        name = "#{expansion} (#{state_label}, #{word_label})"
        after_lines = varop_after_lines(op)
        varop_case(name, varop_setup(state), expansion, after_lines)
      end

    extra_default_one ++ word_cross
  end

  # Nounset must not fire on the operators that exist to handle unset.
  # One revealing cell per family, plus the word-ops on unset (and on
  # empty for the colon forms, where empty is the other trigger).
  defp varop_nounset_cases do
    Enum.concat([
      for {op, _kind} <- @varop_word_ops,
          {state_label, state} <- [{"unset", :unset}, {"empty", :empty}] do
        expansion = "${v#{op}word}"

        varop_case(
          "set -u #{expansion} (#{state_label})",
          varop_setup_u(state),
          expansion,
          varop_after_lines(op)
        )
      end,
      [
        varop_case("set -u ${#v} (unset)", varop_setup_u(:unset), "${#v}", []),
        varop_case("set -u ${v:0} (unset)", varop_setup_u(:unset), "${v:0}", []),
        varop_case("set -u ${v#x} (unset)", varop_setup_u(:unset), "${v#x}", []),
        varop_case("set -u ${v/x/y} (unset)", varop_setup_u(:unset), "${v/x/y}", [])
      ]
    ])
  end

  defp varop_length_cases do
    for {label, state} <- @varop_states do
      varop_case("${#v} (#{label})", varop_setup(state), "${#v}", [])
    end
  end

  defp varop_slice_cases do
    for slice <- @varop_slices, {label, state} <- @varop_states do
      expansion = "${v#{slice}}"
      varop_case("#{expansion} (#{label})", varop_setup(state), expansion, [])
    end
  end

  defp varop_remove_cases do
    Enum.concat([
      for {op, pats} <- [
            {"#", @varop_prefix_pats},
            {"##", @varop_prefix_pats},
            {"%", @varop_suffix_pats},
            {"%%", @varop_suffix_pats}
          ],
          pat <- pats,
          {label, state} <- @varop_states do
        expansion = "${v#{op}#{pat}}"
        varop_case("#{expansion} (#{label})", varop_setup(state), expansion, [])
      end,
      # `foofoo` is where `#` vs `##` and `%` vs `%%` actually split
      # on a repeated literal, not only on `*`.
      for {op, pat} <- [
            {"#", "f*"},
            {"##", "f*"},
            {"#", "foo*"},
            {"##", "foo*"},
            {"%", "*o"},
            {"%%", "*o"},
            {"%", "*foo"},
            {"%%", "*foo"}
          ] do
        expansion = "${v#{op}#{pat}}"
        varop_case("#{expansion} (foofoo)", varop_setup({:set, "foofoo"}), expansion, [])
      end
    ])
  end

  defp varop_replace_cases do
    Enum.concat([
      for all? <- [false, true],
          {pat, rep} <- @varop_replaces,
          {label, state} <- @varop_states do
        slash = if all?, do: "//", else: "/"
        expansion = "${v#{slash}#{pat}/#{rep}}"
        varop_case("#{expansion} (#{label})", varop_setup(state), expansion, [])
      end,
      [
        varop_case("${v/foo/X} (foofoo)", varop_setup({:set, "foofoo"}), "${v/foo/X}", []),
        varop_case("${v//foo/X} (foofoo)", varop_setup({:set, "foofoo"}), "${v//foo/X}", []),
        varop_case("${v/} (foo)", varop_setup({:set, "foo"}), "${v/}", []),
        varop_case("${v//} (foo)", varop_setup({:set, "foo"}), "${v//}", []),
        varop_case("${v/o} (foo)", varop_setup({:set, "foo"}), "${v/o}", []),
        varop_case("${v//o} (foo)", varop_setup({:set, "foo"}), "${v//o}", [])
      ]
    ])
  end

  defp varop_setup(:unset), do: "set +u; unset v"
  defp varop_setup(:empty), do: "set +u; v="
  defp varop_setup({:set, value}), do: "set +u; v=#{value}"

  defp varop_setup_u(:unset), do: "set -u; unset v"
  defp varop_setup_u(:empty), do: "set -u; v="

  defp varop_after_lines(op) when op in ["=", ":="], do: ["echo \"[$v]\""]
  defp varop_after_lines(op) when op in ["?", ":?"], do: ["echo after"]
  defp varop_after_lines(_op), do: []

  defp varop_case(name, setup, expansion, after_lines) do
    echoes = ["echo \"[#{expansion}]\"" | after_lines]
    script = Enum.join([setup | echoes] ++ ["echo rc=$?"], "; ")
    fixture_case("varop matrix: #{name}", script, varop_gap(name))
  end

  # Assigned after recording. A cell that matches is left unmarked even
  # when a sibling of the same operator diverges — marking a match
  # inverts a passing assertion. `${v?}` on a set or empty value is
  # correct; only the unset (and, for `:?`, empty) triggers are gaps.
  @error_op_gap "JustBash ${v?}/${v:?} returns empty and continues; bash writes a diagnostic to stderr and aborts"
  @nounset_other_gap "JustBash set -u treats unset as empty for ${#v}/${v:offset}/${v#pat}/${v/pat}; bash errors unbound variable"
  @slice_neg_empty_gap "JustBash ${v:0:-1} on empty is empty at exit 0; bash errors substring expression < 0"
  @shortest_star_gap "JustBash shortest #/*/% of * consumes one character; bash's shortest * match is empty so the value is unchanged"

  @error_op_names [
    "${v?word} (unset, word)",
    "${v?} (unset, empty)",
    "${v:?word} (unset, word)",
    "${v:?word} (empty, word)",
    "${v:?} (unset, empty)",
    "${v:?} (empty, empty)",
    "set -u ${v?word} (unset)",
    "set -u ${v:?word} (unset)",
    "set -u ${v:?word} (empty)"
  ]

  @nounset_other_names [
    "set -u ${#v} (unset)",
    "set -u ${v:0} (unset)",
    "set -u ${v#x} (unset)",
    "set -u ${v/x/y} (unset)"
  ]

  @shortest_star_names [
    "${v#*} (foo)",
    "${v#*} (foobar)",
    "${v%*} (foo)",
    "${v%*} (foobar)"
  ]

  defp varop_gap(name) do
    cond do
      name in @error_op_names -> @error_op_gap
      name in @nounset_other_names -> @nounset_other_gap
      name == "${v:0:-1} (empty)" -> @slice_neg_empty_gap
      name in @shortest_star_names -> @shortest_star_gap
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # flags — registry-wide unknown-flag probe
  #
  # The alphabet is every name in Commands.Registry × {--jb-not-a-flag, -Z}.
  # A new Registry command must be classified below or `mix bash_fixtures.gen
  # flags` fails — the same completeness rule as end_of_options_test.exs.
  #
  # The probe's default claim is "non-zero exit, usage-bearing stderr, never
  # exit 0". Commands that legitimately treat the token as data, accept GNU
  # `-Z`, or have no twin are still generated; the reason lives here so an
  # omit cannot hide as a pass.
  #
  # Gaps are assigned after recording, never by omitting a cell. Marking a
  # gap must not change the digest — the reason lives in opts.
  # ---------------------------------------------------------------------------

  @flags_probes ["--jb-not-a-flag", "-Z"]

  # Every Registry name. The value is why this command is classified rather
  # than omitted: a probe that bash refuses, an operand that both engines
  # print, a GNU `-Z` that is a real flag, or a JustBash-only command.
  @flags_classifications %{
    "." => "bash source builtin: unknown flag is invalid option + usage",
    ":" => "alias of true; ignores operands and exits 0",
    "[" => "missing ] is a usage-bearing syntax error; not the operand form of test",
    "arch" => "probe: coreutils refuse an unknown flag",
    "awk" => "probe: gawk refuses an unknown flag",
    "base64" => "probe: coreutils refuse an unknown flag",
    "basename" => "probe: coreutils refuse an unknown flag",
    "break" => "bash ignores the token and warns only meaningful in a loop at exit 0",
    "cat" => "probe: coreutils refuse an unknown flag",
    "cd" => "probe: bash builtin refuses an unknown flag + usage",
    "chmod" => "probe: coreutils refuse an unknown flag",
    "chown" => "probe: coreutils refuse an unknown flag",
    "comm" => "probe: coreutils refuse an unknown flag",
    "command" => "probe: bash builtin refuses an unknown flag + usage",
    "continue" => "bash ignores the token and warns only meaningful in a loop at exit 0",
    "cp" => "GNU -Z is SELinux context of the copy; --jb-not-a-flag is refused",
    "curl" => "GNU -Z is --parallel; --jb-not-a-flag is unknown",
    "cut" => "probe: coreutils refuse an unknown flag",
    "date" => "probe: coreutils refuse an unknown flag",
    "declare" => "probe: bash builtin refuses an unknown flag + usage",
    "diff" => "GNU -Z ignores trailing whitespace; --jb-not-a-flag is refused",
    "dirname" => "probe: coreutils refuse an unknown flag",
    "du" => "probe: coreutils refuse an unknown flag",
    "echo" => "operand: writes arguments; -Z and --jb-not-a-flag are data at exit 0",
    "env" => "probe: coreutils refuse an unknown flag",
    "eval" => "probe: bash builtin refuses an unknown flag + usage",
    "exit" => "bash wants a numeric status; the token is not a flag",
    "expand" => "probe: coreutils refuse an unknown flag",
    "export" => "probe: bash builtin refuses an unknown flag + usage",
    "false" => "ignores operands and exits 1 with no diagnostic",
    "file" => "GNU -Z tries to uncompress; --jb-not-a-flag is refused",
    "find" => "probe: GNU find reports an unknown predicate",
    "fold" => "probe: coreutils refuse an unknown flag",
    "getopts" => "probe: bash builtin refuses an unknown flag + usage",
    "grep" => "GNU -Z is --null; --jb-not-a-flag is refused",
    "head" => "probe: coreutils refuse an unknown flag",
    "hostname" => "probe: hostname refuses an unknown flag + usage",
    "id" => "GNU -Z is SELinux context; --jb-not-a-flag is refused",
    "jq" => "probe: jq refuses an unknown flag",
    "ln" => "probe: coreutils refuse an unknown flag",
    "local" => "bash errors can only be used in a function before flag parsing",
    "ls" => "GNU -Z prints SELinux context (empty dir so the listing is deterministic)",
    "markdown" => "JustBash-only; bash has no markdown",
    "md" => "alias of markdown; bash has no md",
    "md5sum" => "probe: coreutils refuse an unknown flag",
    "mkdir" => "GNU -Z is SELinux context of the directory; --jb-not-a-flag is refused",
    "mktemp" => "probe: coreutils refuse an unknown flag",
    "mv" => "GNU -Z is SELinux context of the rename; --jb-not-a-flag is refused",
    "nl" => "probe: coreutils refuse an unknown flag",
    "nproc" => "probe: coreutils refuse an unknown flag",
    "od" => "probe: coreutils refuse an unknown flag",
    "paste" => "probe: coreutils refuse an unknown flag",
    "printenv" => "probe: coreutils refuse an unknown flag",
    "printf" => "probe: bash builtin refuses an unknown flag + usage",
    "pwd" => "probe: bash builtin refuses an unknown flag + usage",
    "read" => "probe: bash builtin refuses an unknown flag + usage",
    "readlink" => "probe: coreutils refuse an unknown flag",
    "realpath" => "probe: coreutils refuse an unknown flag",
    "return" => "bash wants a numeric status; the token is not a flag",
    "rev" => "probe: util-linux refuse an unknown flag",
    "rm" => "probe: coreutils refuse an unknown flag",
    "sed" => "probe: GNU sed refuses an unknown flag + usage",
    "seq" => "probe: coreutils refuse an unknown flag",
    "set" => "probe: bash builtin refuses an unknown flag + usage",
    "sha256sum" => "probe: coreutils refuse an unknown flag",
    "shasum" => "probe: Perl shasum refuses an unknown flag",
    "shift" => "bash wants a numeric count; the token is not a flag",
    "sleep" => "probe: coreutils refuse an unknown flag",
    "sort" => "probe: coreutils refuse an unknown flag",
    "source" => "bash source builtin: unknown flag is invalid option + usage",
    "stat" => "probe: coreutils refuse an unknown flag",
    "tac" => "probe: coreutils refuse an unknown flag",
    "tail" => "probe: coreutils refuse an unknown flag",
    "tee" => "probe: coreutils refuse an unknown flag",
    "test" => "operand: one-arg test is implicit -n; -Z and --jb-not-a-flag are nonempty",
    "touch" => "probe: coreutils refuse an unknown flag",
    "tr" => "probe: coreutils refuse an unknown flag",
    "trap" => "probe: bash builtin refuses an unknown flag + usage",
    "tree" => "probe: tree refuses an unknown flag + usage",
    "true" => "ignores operands and exits 0",
    "type" => "probe: bash builtin refuses an unknown flag + usage",
    "typeset" => "probe: bash builtin refuses an unknown flag + usage",
    "uname" => "probe: coreutils refuse an unknown flag",
    "uniq" => "probe: coreutils refuse an unknown flag",
    "unset" => "probe: bash builtin refuses an unknown flag + usage",
    "wc" => "probe: coreutils refuse an unknown flag",
    "wget" => "probe: wget refuses an unknown flag + usage",
    "which" => "probe: which refuses an unknown flag + usage",
    "whoami" => "probe: coreutils refuse an unknown flag",
    "xargs" => "probe: findutils refuse an unknown flag",
    "xxd" => "probe: xxd refuses an unknown flag + usage",
    "yes" => "GNU yes refuses unknown flags; they are not the string to repeat"
  }

  # Assigned after recording. A cell that matches is left unmarked even
  # when a sibling of the same command diverges — marking a match inverts
  # a passing assertion. Per-flag overrides win over the per-command map.
  @absorbed_gap "JustBash absorbs the flag as an operand or format and exits 0; bash refuses it"
  @misblame_gap "JustBash treats the flag as a filename or other operand and exits non-zero; bash names the option"
  @wording_gap "both refuse the flag; JustBash's diagnostic wording or exit code differs from bash/coreutils"
  @selinux_z_gap "GNU -Z is a real flag (SELinux context); JustBash rejects -Z as unknown or mishandles it"
  @gnu_z_gap "GNU -Z is a real flag; JustBash rejects -Z as unknown or mishandles it"
  @no_gnu_gap "JustBash-only command; bash reports command not found"
  @quiet_gap "JustBash exits non-zero with no diagnostic; bash writes usage or a required-argument error"
  @loop_gap "JustBash does not emit bash's only meaningful in a loop warning"
  @local_gap "JustBash local/declare parses flags outside a function; bash errors can only be used in a function or refuses the option"
  @numeric_gap "JustBash does not diagnose a non-numeric status/count the way bash does"
  @yes_gap "JustBash yes treats the flag as the string to repeat; GNU yes refuses unknown flags"
  @bracket_gap "JustBash [ without a closing ] still evaluates the token; bash exits 2 and diagnoses missing ]"

  # Per-command default, applied to both probes unless overridden.
  # Filled after the first recording; matching cells stay nil.
  @flags_command_gaps %{
    "." => @misblame_gap,
    "[" => @bracket_gap,
    "arch" => @absorbed_gap,
    "awk" => @absorbed_gap,
    "base64" => @wording_gap,
    "basename" => @absorbed_gap,
    "break" => @loop_gap,
    "cat" => @misblame_gap,
    "cd" => @misblame_gap,
    "chmod" => @misblame_gap,
    "chown" => @misblame_gap,
    "comm" => @wording_gap,
    "command" => @misblame_gap,
    "continue" => @loop_gap,
    "cut" => @wording_gap,
    "curl" => @misblame_gap,
    "date" => @wording_gap,
    "declare" => @local_gap,
    "diff" => @wording_gap,
    "dirname" => @absorbed_gap,
    "du" => @wording_gap,
    "env" => @wording_gap,
    "eval" => @misblame_gap,
    "expand" => @wording_gap,
    "exit" => @numeric_gap,
    "export" => @absorbed_gap,
    "file" => @wording_gap,
    "find" => @misblame_gap,
    "fold" => @wording_gap,
    "getopts" => @misblame_gap,
    "hostname" => @absorbed_gap,
    "id" => @absorbed_gap,
    "jq" => @misblame_gap,
    "ln" => @misblame_gap,
    "local" => @local_gap,
    "md5sum" => @wording_gap,
    "markdown" => @no_gnu_gap,
    "md" => @no_gnu_gap,
    "mkdir" => @absorbed_gap,
    "mktemp" => @absorbed_gap,
    "mv" => @misblame_gap,
    "nl" => @wording_gap,
    "nproc" => @absorbed_gap,
    "od" => @misblame_gap,
    "paste" => @wording_gap,
    "printenv" => @absorbed_gap,
    "printf" => @absorbed_gap,
    "pwd" => @absorbed_gap,
    "read" => @quiet_gap,
    "readlink" => @wording_gap,
    "realpath" => @misblame_gap,
    "return" => @numeric_gap,
    "rev" => @absorbed_gap,
    "rm" => @misblame_gap,
    "sed" => @wording_gap,
    "seq" => @misblame_gap,
    "set" => @wording_gap,
    "sha256sum" => @misblame_gap,
    "shasum" => @misblame_gap,
    "shift" => @numeric_gap,
    "sleep" => @absorbed_gap,
    "source" => @misblame_gap,
    "stat" => @wording_gap,
    "tac" => @absorbed_gap,
    "touch" => @absorbed_gap,
    "tee" => @wording_gap,
    "trap" => @misblame_gap,
    "tree" => @wording_gap,
    "type" => @misblame_gap,
    "typeset" => @local_gap,
    "uname" => @absorbed_gap,
    "unset" => @absorbed_gap,
    "wc" => @misblame_gap,
    "wget" => @misblame_gap,
    "which" => @wording_gap,
    "whoami" => @absorbed_gap,
    "xargs" => @wording_gap,
    "xxd" => @misblame_gap,
    "yes" => @yes_gap
  }

  # Per-flag overrides. GNU `-Z` that is a real option is a different
  # divergence from `--jb-not-a-flag` on the same command.
  @flags_gap_overrides %{
    {"cp", "-Z"} => @selinux_z_gap,
    {"curl", "-Z"} => @gnu_z_gap,
    {"diff", "-Z"} => @gnu_z_gap,
    {"file", "-Z"} => @gnu_z_gap,
    {"grep", "-Z"} => @gnu_z_gap,
    {"id", "-Z"} => @selinux_z_gap,
    {"ls", "-Z"} => @selinux_z_gap,
    {"mkdir", "-Z"} => @selinux_z_gap,
    {"mv", "-Z"} => @selinux_z_gap
  }

  @doc false
  def flags_classifications, do: @flags_classifications

  defp flags_cases do
    assert_registry_classified!()

    for name <- flags_names(), flag <- @flags_probes do
      flags_case(name, flag)
    end
  end

  defp flags_names, do: @flags_classifications |> Map.keys() |> Enum.sort()

  defp assert_registry_classified! do
    classified = flags_names()
    registry = Registry.list() |> Enum.sort()

    unless classified == registry do
      Mix.raise("""
      flags matrix classification does not match Commands.Registry:
        missing: #{inspect(registry -- classified)}
        extra: #{inspect(classified -- registry)}
      """)
    end
  end

  defp flags_case(name, flag) do
    fixture_case(
      "flags matrix: #{name} #{flag}",
      flags_script(name, flag),
      flags_gap(name, flag)
    )
  end

  # `ls -Z` lists the current directory under GNU. Pin an empty workdir so
  # the recording is not the workspace listing.
  defp flags_script("ls", "-Z") do
    ~S[D=/tmp/jb_flags_ls; mkdir -p "$D"; LC_ALL=C LANG=C ls -Z "$D"; echo rc=$?]
  end

  defp flags_script(name, flag) do
    "LC_ALL=C LANG=C #{name} #{flag}; echo rc=$?"
  end

  defp flags_gap(name, flag) do
    Map.get(@flags_gap_overrides, {name, flag}, Map.get(@flags_command_gaps, name))
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
