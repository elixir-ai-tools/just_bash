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

    * `date` — every strftime directive alone and adjacently paired, `-I`
      granularities, `-d` input forms, and flags GNU date does not have

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

  @date_modifiers [":z", "::z", ":::z", "-d", "_d", "0d", "^a", "#a"]

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
    "%^!"
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
    "%-j"
  ]

  # %N is a fractional-seconds field: a width truncates its nine digits rather
  # than padding them. GNU's handling of the space and no-pad flags here is
  # stranger — `%_N` right-pads with spaces, which no other conversion does — so
  # those combinations are recorded as gaps rather than imitated.
  @nanosecond_gap "GNU pads %N with trailing spaces under _ and -, unlike every other conversion"

  @date_nanoseconds [
    {"%N", nil},
    {"%-N", nil},
    {"%0N", nil},
    {"%^N", nil},
    {"%3N", nil},
    {"%6N", nil},
    {"%_N", @nanosecond_gap},
    {"%-3N", @nanosecond_gap},
    {"%_6N", @nanosecond_gap}
  ]

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
    {"-jf %Y", @bsd_gap},
    {"--not-a-flag", @bsd_usage_gap},
    {"-Z", @bsd_usage_gap}
  ]

  # Two base instants, because one cannot distinguish padding. At day 15 and hour
  # 13, `%-d`, `%_d` and `%0d` all render "15" and every padding bug hides; at day
  # 5 and hour 9 they render "5", " 5" and "05". The single-digit base also puts
  # the hour before noon, so %I/%p/%P/%l/%k differ from the afternoon base.
  @base "2024-06-15 13:30:00"
  @base_single "2024-06-05 09:05:03"

  @bases [{"pm", @base}, {"am", @base_single}]

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
      for d <- @date_directives, {label, base} <- @bases do
        date_case("directive %#{d} (#{label})", "'+%#{d}'", base)
      end,
      for m <- @date_modifiers, {label, base} <- @bases do
        date_case("modifier %#{m} (#{label})", "'+%#{m}'", base)
      end,
      for f <- @date_pairs do
        date_case("sequence #{f}", "'+#{f}'")
      end,
      for f <- @date_widths do
        date_case("width #{f}", "'+#{f}'", @base_single)
      end,
      for {f, gap} <- @date_nanoseconds do
        one_case(
          "nanoseconds #{f}",
          "TZ=UTC LC_ALL=C date -d '#{@base_single}' '+#{f}'; echo rc=$?",
          gap
        )
      end,
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
        # Both shells refuse the flag; only the wording of the refusal differs.
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
