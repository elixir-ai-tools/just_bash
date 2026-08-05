defmodule JustBash.Commands.UtilitiesTest do
  use ExUnit.Case, async: true

  alias JustBash.Commands.Env

  describe "xxd command" do
    test "xxd produces a canonical hex+ASCII dump of stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n hello | xxd")
      assert result.exit_code == 0
      assert result.stdout =~ "6865 6c6c 6f"
      assert result.stdout =~ "hello"
    end
  end

  describe "od command" do
    test "od -c shows characters" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n hi | od -c")
      assert result.exit_code == 0
      assert result.stdout =~ "h"
      assert result.stdout =~ "i"
    end
  end

  describe "basic commands" do
    test "echo with multiple arguments" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo a b c")
      assert result.stdout == "a b c\n"
    end

    test "echo -n suppresses newline" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n hello")
      assert result.stdout == "hello"
    end

    test "echo -e interprets escapes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'hello\\nworld'")
      assert result.stdout == "hello\nworld\n"
    end

    test "pwd shows current directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "pwd")
      assert result.stdout == "/home/user\n"
    end

    test "true returns 0" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true")
      assert result.exit_code == 0
    end

    test "false returns 1" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "false")
      assert result.exit_code == 1
    end

    test ": (colon) is a no-op that returns 0" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ":")
      assert result.exit_code == 0
    end
  end

  describe "echo command extended" do
    test "echo with -E flag disables escapes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -E "hello\nworld"])
      assert result.stdout == "hello\\nworld\n"
    end

    test "echo with -ne combined flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -ne "hello\nworld"])
      assert result.stdout == "hello\nworld"
    end

    test "echo with -en combined flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -en "hello\tworld"])
      assert result.stdout == "hello\tworld"
    end

    test "echo with no args outputs newline" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo")
      assert result.stdout == "\n"
    end

    test "echo -e with tab and carriage return" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -e "a\tb\rc"])
      assert result.stdout == "a\tb\rc\n"
    end

    test "echo -e with escaped backslash" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[echo -e "back\\\\slash"])
      assert result.stdout == "back\\slash\n"
    end
  end

  describe "printf command" do
    test "printf formats output" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'Hello %s\\n' World")
      assert result.stdout == "Hello World\n"
    end

    test "printf with %d format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'num: %d' 42")
      assert result.stdout == "num: 42"
    end

    test "printf with multiple args" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%s=%s' key value")
      assert result.stdout == "key=value"
    end

    test "printf missing args uses defaults" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a:%s:b:%d:'")
      assert result.stdout == "a::b:0:"
    end

    test "printf with tab escape" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[printf "a\tb"])
      assert result.stdout == "a\tb"
    end

    test "printf %b expands escape sequences in the argument" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[printf "%b" "A\tB\n"])
      assert result.stdout == "A\tB\n"
      assert result.exit_code == 0
    end

    @tag timeout: 5_000
    test "printf %b with hex escapes emits raw bytes and terminates" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[printf "%b" "A\xffB\n"])
      assert result.stdout == <<?A, 0xFF, ?B, ?\n>>
    end

    test "printf %b recycles the format across arguments" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[printf "%b\n" "a\tb" "c"])
      assert result.stdout == "a\tb\nc\n"
    end

    # Bash errors on unknown directives; we pass them through literally.
    # Either way, a directive that consumes no argument must not recycle
    # the format forever.
    @tag timeout: 5_000
    test "printf with an unrecognized directive terminates instead of looping" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S[printf "%v\n" x])
      assert result.stdout == "%v\n"
    end

    test "printf with %x hex format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%x' 255")
      assert result.stdout == "ff"
    end

    test "printf with %X uppercase hex format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%X' 255")
      assert result.stdout == "FF"
    end

    test "printf with %o octal format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%o' 64")
      assert result.stdout == "100"
    end

    test "printf with %f float format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%f' 3.14159")
      assert result.stdout == "3.141590"
    end

    test "printf with %f precision" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%.2f' 3.14159")
      assert result.stdout == "3.14"
    end

    test "printf with width specifier" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%10s' hello")
      assert result.stdout == "     hello"
    end

    test "printf with left-align" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%-10s' hello")
      assert result.stdout == "hello     "
    end

    test "printf with %c character format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%c' abc")
      assert result.stdout == "a"
    end

    test "printf with %% literal percent" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '100%%'")
      assert result.stdout == "100%"
    end

    test "printf with %e scientific notation" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf '%e' 12345")
      assert result.stdout =~ ~r/1\.\d+e\+0?4/i
    end
  end

  describe "date -r" do
    # The date matrix covers -r's error paths against real bash, but not its
    # success path: the mtime of a file created during recording is the recording
    # clock's, so the two engines cannot agree on it by construction. Seeding a
    # known mtime is the only way to assert the value.
    setup do
      bash = JustBash.new()
      {_result, bash} = JustBash.exec(bash, "echo hi > /ref.txt")

      mtime = ~U[2021-03-04 05:06:07Z]
      {:ok, fs} = JustBash.FS.write_file(bash.fs, "/ref.txt", "hi\n", mtime: mtime)

      %{bash: %{bash | fs: fs}, mtime: mtime}
    end

    test "reports the reference file's modification time", %{bash: bash} do
      {result, _} = JustBash.exec(bash, "date -r /ref.txt '+%F %T'")

      assert result.exit_code == 0
      assert result.stdout == "2021-03-04 05:06:07\n"
    end

    test "accepts the long spelling", %{bash: bash} do
      {result, _} = JustBash.exec(bash, "date --reference=/ref.txt '+%F'")

      assert result.exit_code == 0
      assert result.stdout == "2021-03-04\n"
    end

    test "resolves a relative path against the working directory", %{bash: bash} do
      {result, _} = JustBash.exec(bash, "cd / && date -r ref.txt '+%F'")

      assert result.exit_code == 0
      assert result.stdout == "2021-03-04\n"
    end

    test "reports the real error kind, not a hardcoded one", %{bash: bash} do
      {result, _} = JustBash.exec(bash, "date -r /ref.txt/nope '+%F'")

      assert result.exit_code == 1
      # /ref.txt is a regular file, so descending through it is ENOTDIR — the
      # message must not claim the file is merely absent.
      assert result.stderr == "date: /ref.txt/nope: Not a directory\n"
    end

    test "accepts the long spelling with a separate argument", %{bash: bash} do
      {result, _} = JustBash.exec(bash, "date --reference /ref.txt '+%F'")

      assert result.exit_code == 0
      assert result.stdout == "2021-03-04\n"
    end

    # The matrix records the mutual exclusion against real bash, but only in the
    # direction `-r` then `-d`; a reference the recorder can seed does not exist,
    # so the other order is asserted here.
    test "refuses -d after -r rather than picking one", %{bash: bash} do
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15' -r /ref.txt '+%F'")

      assert result.exit_code == 1
      assert result.stdout == ""

      assert result.stderr =~
               "date: the options to specify dates for printing are mutually exclusive\n"

      assert result.stderr =~ "usage: date"
    end
  end

  describe "date command" do
    test "date outputs current date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/\d{4}/
    end

    test "date outputs formatted time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/\d{4}/
      assert result.stdout =~ "UTC"
    end

    test "date with custom format +%Y-%m-%d" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date '+%Y-%m-%d'")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/^\d{4}-\d{2}-\d{2}\n$/
    end

    test "date with -d for specific date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-01-15' '+%Y-%m-%d'")
      assert result.exit_code == 0
      assert result.stdout == "2024-01-15\n"
    end

    test "date with unix timestamp format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-01-01' '+%s'")
      assert result.exit_code == 0
      assert result.stdout == "1704067200\n"
    end

    test "date with weekday format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-01-15' '+%A'")
      assert result.exit_code == 0
      assert result.stdout == "Monday\n"
    end

    test "date with month format" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-03-01' '+%B'")
      assert result.exit_code == 0
      assert result.stdout == "March\n"
    end

    test "date with invalid date returns error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d 'not-a-date'")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid date"
    end
  end

  describe "compound format specifiers" do
    test "%F is the ISO date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' '+%F'")
      assert result.exit_code == 0
      assert result.stdout == "2024-06-15\n"
    end

    test "%T is the 24-hour time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:05' '+%T'")
      assert result.stdout == "10:30:05\n"
    end

    test "%D is the US short date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' '+%D'")
      assert result.stdout == "06/15/24\n"
    end

    test "%R is hours and minutes" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:05' '+%R'")
      assert result.stdout == "10:30\n"
    end

    test "%F and %T compose" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:05' '+%F %T'")
      assert result.stdout == "2024-06-15 10:30:05\n"
    end
  end

  describe "single-field format specifiers" do
    test "%y is the two-digit year and %C the century" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:00:00' '+%y %C'")
      assert result.stdout == "24 20\n"
    end

    test "%e is the space-padded day of month" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-05 00:00:00' '+[%e]'")
      assert result.stdout == "[ 5]\n"
    end

    test "%I and %p are the 12-hour clock" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 13:30:00' '+%I %p'")
      assert result.stdout == "01 PM\n"
    end

    test "%I renders midnight as 12 AM" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:30:00' '+%I %p'")
      assert result.stdout == "12 AM\n"
    end

    test "%P is the lowercase %p" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 13:30:00' '+%P'")
      assert result.stdout == "pm\n"
    end

    test "%P renders midnight as am" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:30:00' '+%P'")
      assert result.stdout == "am\n"
    end

    test "%Z is the timezone name" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:00:00' '+%Z'")
      assert result.stdout == "UTC\n"
    end

    test "%N is nanoseconds" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15T10:30:00.123456Z' '+%N'")
      assert result.stdout == "123456000\n"
    end
  end

  describe "percent escaping" do
    test "%%F is a literal percent followed by F" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:00:00' '+%%F'")
      assert result.stdout == "%F\n"
    end

    test "%%Y is a literal percent followed by Y" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:00:00' '+%%Y'")
      assert result.stdout == "%Y\n"
    end

    test "a trailing bare percent survives" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:00:00' '+abc%'")
      assert result.stdout == "abc%\n"
    end

    test "an unknown specifier is passed through rather than silently dropped" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 00:00:00' '+%J'")
      assert result.stdout == "%J\n"
    end

    # Format strings are raw binaries, not necessarily valid UTF-8.
    test "a raw non-UTF-8 byte in the format passes through" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~S|date -d '2024-06-15 00:00:00' +$'\xff%Y'|)
      assert result.exit_code == 0
      assert result.stdout == <<0xFF>> <> "2024\n"
    end
  end

  describe "-I / --iso-8601" do
    test "-I prints just the date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' -I")
      assert result.exit_code == 0
      assert result.stdout == "2024-06-15\n"
    end

    test "--iso-8601 is the long form" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' --iso-8601")
      assert result.stdout == "2024-06-15\n"
    end

    test "-Iseconds includes the time and offset" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' -Iseconds")
      assert result.stdout == "2024-06-15T10:30:00+00:00\n"
    end

    test "-Ihours and -Iminutes truncate the time" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:05' -Ihours")
      {r2, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:05' -Iminutes")
      assert r1.stdout == "2024-06-15T10+00:00\n"
      assert r2.stdout == "2024-06-15T10:30+00:00\n"
    end

    test "-Idate is the same as bare -I" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' -Idate")
      assert result.stdout == "2024-06-15\n"
    end

    test "--iso-8601=seconds is the long form with a value" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' --iso-8601=seconds")
      assert result.stdout == "2024-06-15T10:30:00+00:00\n"
    end

    test "-Ins includes the actual nanoseconds" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -d '2024-06-15T10:30:00.123456Z' -Ins")
      {r2, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' -Ins")
      assert r1.stdout == "2024-06-15T10:30:00,123456000+00:00\n"
      assert r2.stdout == "2024-06-15T10:30:00,000000000+00:00\n"
    end

    # Real date rejects competing output formats rather than picking one,
    # in either argument order.
    test "-I together with an explicit +format is an error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' -I '+%Y'")
      assert result.exit_code == 1
      assert result.stderr =~ "multiple output formats specified"
    end

    test "+format followed by -I is also an error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15 10:30:00' '+%Y' -I")
      assert result.exit_code == 1
      assert result.stderr =~ "multiple output formats specified"
    end

    test "an invalid -I argument is an error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -Ibogus")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid argument 'bogus' for '--iso-8601'"
    end

    test "date,ns is rejected as real date rejects it" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date --iso-8601=date,ns")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid argument 'date,ns' for '--iso-8601'"
    end
  end

  # An unimplemented flag must not be dropped: silently ignoring it returns the
  # current date at exit 0, which the caller cannot tell from a real answer.
  describe "unrecognized arguments" do
    # A long option is named in full, as GNU date words it. BSD reports the
    # offending character, which for a long option is the second `-` — a message
    # that identifies nothing.
    test "an unknown long option is an error, not a silently ignored flag" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date --definitely-not-a-flag '+%Y-%m-%d'")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr =~ "date: unrecognized option '--definitely-not-a-flag'\n"
    end

    # A short option is named by its character, as BSD date does, because that
    # is the unit getopt rejected — `-Xu` is a bad `X`, not a bad `Xu`.
    test "an unknown short option is named by its character" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -X '+%Y'")
      {r2, _} = JustBash.exec(bash, "date -Xu '+%Y'")
      assert r1.exit_code == 1
      assert r1.stdout == ""
      assert r1.stderr =~ "date: illegal option -- X\n"
      assert r2.exit_code == 1
      assert r2.stderr =~ "date: illegal option -- X\n"
    end

    # A lone `-` is not option-shaped to getopt, so it is an operand.
    test "a lone dash is an operand, not an option" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -")
      assert result.exit_code == 1
      assert result.stderr =~ "illegal time format"
    end

    test "the error names the supported flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -X")
      assert result.stderr =~ "usage: date"
      assert result.stderr =~ "-v[+|-]val[y|m|w|d|H|M|S]"
    end

    test "a bare operand cannot set the clock" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date 1432")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr =~ "Operation not permitted"
    end

    test "an operand that is not even a settable time is a format error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date notadate")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr =~ "illegal time format"
    end

    # -j means "display, don't set", so the operand is a time we cannot parse
    # rather than a clock we failed to set.
    test "an operand under -j is a format error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -j 0900")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr =~ "illegal time format"
    end

    test "-u is still accepted, since output is always UTC" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -u -d '2024-06-15 10:30:00' '+%F %T'")
      assert result.exit_code == 0
      assert result.stdout == "2024-06-15 10:30:00\n"
    end

    test "a flag whose argument is missing is an error" do
      bash = JustBash.new()

      for flag <- ["-d", "-f", "-r", "-v"] do
        {result, _} = JustBash.exec(bash, "date #{flag}")
        assert result.exit_code == 1, "expected #{flag} with no argument to fail"
        assert result.stderr =~ "option requires an argument -- #{flag}"
      end
    end

    # -f names the format of an operand. With no operand there is nothing for it
    # to parse, so real date prints usage rather than falling back to now — the
    # same defect class as an ignored flag, on the one path that still had it.
    test "-f without an operand is an error, not the current date" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -f '%Y-%m-%d' '+%F'")
      {r2, _} = JustBash.exec(bash, "date -j -f '%Y-%m-%d' '+%F'")
      assert r1.exit_code == 1
      assert r1.stdout == ""
      assert r1.stderr =~ "usage: date"
      assert r2.exit_code == 1
      assert r2.stdout == ""
      assert r2.stderr =~ "usage: date"
    end
  end

  # getopt's conventions, which real date inherits: `--` ends option parsing and
  # no-argument flags may be clustered. Rejecting unknown options meant these
  # two spellings started erroring, so they need to be understood rather than
  # merely tolerated.
  describe "getopt conventions" do
    test "-- ends option parsing" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15' -- '+%F'")
      assert result.exit_code == 0
      assert result.stdout == "2024-06-15\n"
    end

    test "-- alone still prints the date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date --")
      assert result.exit_code == 0
      assert result.stdout =~ ~r/^\w{3} \w{3} \d{2} \d{2}:\d{2}:\d{2} UTC \d{4}\n$/
    end

    # After `--` an option-shaped argument is an operand, so it fails as a time
    # rather than as an option.
    test "an option after -- is an operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -- -X")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr =~ "illegal time format"
      refute result.stderr =~ "illegal option"
    end

    test "no-argument short flags may be clustered" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -ju -d '2024-06-15' '+%F'")
      {r2, _} = JustBash.exec(bash, "date -uj -d '2024-06-15' '+%F'")
      assert r1.exit_code == 0, r1.stderr
      assert r1.stdout == "2024-06-15\n"
      assert r2.stdout == "2024-06-15\n"
    end

    # Inside a cluster the next character is an option character, and `-` is not
    # one. Reading the remainder as a fresh argument instead would turn `-u-`
    # into `-u --` and print the date at exit 0.
    test "a dash inside a cluster is an illegal option, not end-of-options" do
      bash = JustBash.new()

      for arg <- ["-u-", "-u-x", "-ju-"] do
        {result, _} = JustBash.exec(bash, "date #{arg} '+%F'")
        assert result.exit_code == 1, "expected date #{arg} to fail"
        assert result.stdout == ""
        assert result.stderr =~ "date: illegal option -- -\n"
      end
    end

    # A cluster ends at the first flag that takes a value; the remainder is that
    # value, so `-ur0` is `-u -r 0`.
    test "a clustered flag may carry the value of the flag that ends the cluster" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -ur0 '+%F'")
      {r2, _} = JustBash.exec(bash, "date -d '2024-06-15' -ujv+1d '+%F'")
      {r3, _} = JustBash.exec(bash, "date -d '2024-06-15' -uIseconds")
      assert r1.stdout == "1970-01-01\n"
      assert r2.stdout == "2024-06-16\n"
      assert r3.stdout == "2024-06-15T00:00:00+00:00\n"
    end
  end

  describe "-v adjustments" do
    test "+6m moves six months forward" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2026-08-04' -v+6m '+%Y-%m-%d'")
      assert result.exit_code == 0
      assert result.stdout == "2027-02-04\n"
    end

    test "-1y moves a year back" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2026-08-04' -v-1y '+%Y-%m-%d'")
      assert result.stdout == "2025-08-04\n"
    end

    # Bracketing the call rather than reading the clock once keeps the assertion
    # honest across UTC midnight.
    test "the adjustment applies to the current date when there is no -d" do
      bash = JustBash.new()
      before = Date.utc_today()
      {result, _} = JustBash.exec(bash, "date -v+1d '+%Y-%m-%d'")
      after_call = Date.utc_today()

      allowed =
        for day <- [before, after_call], do: "#{Date.to_iso8601(Date.add(day, 1))}\n"

      assert result.stdout in allowed
    end

    test "the value may be a separate argument, as getopt allows" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2026-08-04' -v +6m '+%Y-%m-%d'")
      assert result.stdout == "2027-02-04\n"
    end

    # BSD: "date tries to preserve the day of the month. If it is impossible
    # because the target month is shorter [...] the last day of the target
    # month will be the result."
    test "a month adjustment clamps to the last day of a shorter target month" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -d '2026-01-31' -v+1m '+%Y-%m-%d'")
      {r2, _} = JustBash.exec(bash, "date -d '2026-03-31' -v-1m '+%Y-%m-%d'")
      {r3, _} = JustBash.exec(bash, "date -d '2024-01-31' -v+1m '+%Y-%m-%d'")
      assert r1.stdout == "2026-02-28\n"
      assert r2.stdout == "2026-02-28\n"
      assert r3.stdout == "2024-02-29\n"
    end

    # A year adjustment moves the year field and lets an impossible result
    # normalize forward, where a month adjustment clamps. BSD really does treat
    # the two differently: +1y off Feb 29 is Mar 1, +12m off Feb 29 is Feb 28.
    test "a year adjustment rolls February 29 forward onto a non-leap year" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -d '2024-02-29' -v+1y '+%Y-%m-%d'")
      {r2, _} = JustBash.exec(bash, "date -d '2024-02-29' -v-1y '+%Y-%m-%d'")
      {r3, _} = JustBash.exec(bash, "date -d '2024-02-29' -v+12m '+%Y-%m-%d'")
      {r4, _} = JustBash.exec(bash, "date -d '2024-02-29' -v+4y '+%Y-%m-%d'")
      assert r1.stdout == "2025-03-01\n"
      assert r2.stdout == "2023-03-01\n"
      assert r3.stdout == "2025-02-28\n"
      assert r4.stdout == "2028-02-29\n"
    end

    test "months roll across the year boundary in both directions" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -d '2026-11-15' -v+3m '+%Y-%m-%d'")
      {r2, _} = JustBash.exec(bash, "date -d '2026-02-15' -v-3m '+%Y-%m-%d'")
      assert r1.stdout == "2027-02-15\n"
      assert r2.stdout == "2025-11-15\n"
    end

    test "weeks, days, hours, minutes and seconds each adjust their own field" do
      bash = JustBash.new()
      base = "date -d '2026-08-04 12:30:45'"
      {w, _} = JustBash.exec(bash, "#{base} -v+2w '+%F %T'")
      {d, _} = JustBash.exec(bash, "#{base} -v-3d '+%F %T'")
      {h, _} = JustBash.exec(bash, "#{base} -v+12H '+%F %T'")
      {m, _} = JustBash.exec(bash, "#{base} -v-45M '+%F %T'")
      {s, _} = JustBash.exec(bash, "#{base} -v+20S '+%F %T'")
      assert w.stdout == "2026-08-18 12:30:45\n"
      assert d.stdout == "2026-08-01 12:30:45\n"
      assert h.stdout == "2026-08-05 00:30:45\n"
      assert m.stdout == "2026-08-04 11:45:45\n"
      assert s.stdout == "2026-08-04 12:31:05\n"
    end

    # BSD: "Flags are processed in the order given." March 31 is a base where the
    # two orders genuinely disagree: +1m clamps to April 30 before -1d takes a
    # day off, where -1d lands on March 30 first and +1m then keeps the 30th. A
    # base like August 4 gives the same answer either way and so cannot tell an
    # ordered fold from a reversed one.
    test "several adjustments compose left to right" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -d '2026-03-31' -v+1m -v-1d '+%Y-%m-%d'")
      {r2, _} = JustBash.exec(bash, "date -d '2026-03-31' -v-1d -v+1m '+%Y-%m-%d'")
      assert r1.stdout == "2026-04-29\n"
      assert r2.stdout == "2026-04-30\n"
    end

    test "an unsigned adjustment sets rather than adjusts, and is not supported" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -v1d '+%Y-%m-%d'")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr =~ "1d: Cannot apply date adjustment"
    end

    # `%Y` is four digits and -d only parses ISO dates, so the representable
    # range is the ISO calendar's. Leaving it must be an error, not a year like
    # -97973 printed at exit 0.
    test "an adjustment that leaves the representable range is an error" do
      bash = JustBash.new()

      for spec <- ["-99999y", "+99999y", "+9999999999m", "+9999999999999d", "-3000y"] do
        {result, _} = JustBash.exec(bash, "date -v#{spec} '+%Y-%m-%d'")
        assert result.exit_code == 1, "expected -v#{spec} to fail"
        assert result.stdout == ""
        assert result.stderr =~ "#{spec}: Cannot apply date adjustment"
      end
    end

    test "an intermediate adjustment out of range fails even if the total is in range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d '2024-06-15' -v+9000y -v-9000y '+%Y-%m-%d'")
      assert result.exit_code == 1
      assert result.stderr =~ "+9000y: Cannot apply date adjustment"
    end

    test "an adjustment at the edge of the range still works" do
      bash = JustBash.new()
      {r1, _} = JustBash.exec(bash, "date -d '2024-06-15' -v+7975y '+%Y-%m-%d'")
      {r2, _} = JustBash.exec(bash, "date -d '2024-06-15' -v-2024y '+%Y-%m-%d'")
      assert r1.stdout == "9999-06-15\n"
      assert r2.stdout == "0000-06-15\n"
    end

    test "an unparseable adjustment is an error" do
      bash = JustBash.new()

      for spec <- ["bogus", "+fri", "+1x", "+m", "+1.5d"] do
        {result, _} = JustBash.exec(bash, "date -v#{spec} '+%Y-%m-%d'")
        assert result.exit_code == 1, "expected -v#{spec} to fail"
        assert result.stderr =~ "#{spec}: Cannot apply date adjustment"
      end
    end

    # An out-of-range adjustment has to be rejected before it is applied, not
    # after: the fixed-length units go through DateTime.add/3, whose cost grows
    # with how far the result lands from the epoch, so 10^20 days does not come
    # back at all. This asserts termination first — a rejection that arrives in a
    # week is not a rejection.
    test "an enormous adjustment is rejected rather than computed" do
      for unit <- ~w(y m w d H M S), sign <- ~w(+ -) do
        spec = "#{sign}#{String.duplicate("9", 20)}#{unit}"

        task =
          Task.async(fn -> JustBash.exec(JustBash.new(), "date -v#{spec} '+%Y-%m-%d'") end)

        case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {result, _}} ->
            assert result.exit_code == 1, "expected -v#{spec} to fail"
            assert result.stdout == ""
            assert result.stderr =~ "#{spec}: Cannot apply date adjustment"

          nil ->
            flunk("date -v#{spec} did not terminate within 2s")
        end
      end
    end

    # The bound on a fixed-length unit has to be the whole ISO calendar, not a
    # convenient round number: these two adjustments span it exactly, from the
    # first representable day to the last.
    test "an adjustment spanning the whole calendar is still applied" do
      bash = JustBash.new()
      {days, _} = JustBash.exec(bash, "date -d '0000-01-01' -v+3652424d '+%Y-%m-%d'")
      {secs, _} = JustBash.exec(bash, "date -d '0000-01-01' -v+315569433600S '+%Y-%m-%d'")
      assert days.stdout == "9999-12-31\n", days.stderr
      assert secs.stdout == "9999-12-31\n", secs.stderr
    end
  end

  describe "-r seconds" do
    test "-r 0 is the epoch" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -r 0 '+%Y-%m-%d %H:%M:%S'")
      assert result.exit_code == 0
      assert result.stdout == "1970-01-01 00:00:00\n"
    end

    test "-r takes the value attached too" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -r1718409600 '+%Y-%m-%d'")
      assert result.stdout == "2024-06-15\n"
    end

    test "-r accepts a negative timestamp" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -r -1 '+%Y-%m-%d %H:%M:%S'")
      assert result.stdout == "1969-12-31 23:59:59\n"
    end

    test "-r composes with -v" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -r 0 -v+1y '+%Y-%m-%d'")
      assert result.stdout == "1971-01-01\n"
    end

    test "a timestamp outside the representable range is an error, not a crash" do
      bash = JustBash.new()

      for secs <- ["99999999999999999999", "-99999999999999999999"] do
        {result, _} = JustBash.exec(bash, "date -r #{secs} '+%Y-%m-%d'")
        assert result.exit_code == 1, "expected -r #{secs} to fail"
        assert result.stdout == ""
        assert result.stderr =~ "invalid time"
      end
    end

    # A non-numeric value is the other spelling of the same flag — a file to read
    # a modification time from — so it is answered or refused as a file, never as
    # a number that failed to parse.
    test "a non-numeric -r argument names a file, not a malformed timestamp" do
      bash = JustBash.new(files: %{"/tmp/f.txt" => "hi"})
      {result, _} = JustBash.exec(bash, "date -r /tmp/f.txt '+%Y-%m-%d'")
      assert result.exit_code == 0, result.stderr
      refute result.stderr =~ "illegal time value"
    end

    test "a non-numeric -r argument that names nothing is an error, not the current date" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -r /tmp/absent.txt '+%Y-%m-%d'")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr == "date: /tmp/absent.txt: No such file or directory\n"
    end
  end

  describe "-d attached value" do
    test "-d takes the date attached, as GNU date allows" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -d2024-06-15 '+%Y-%m-%d'")
      assert result.stdout == "2024-06-15\n"
    end

    test "an attached -d value is still validated" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "date -dnonsense")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid date 'nonsense'"
    end
  end

  describe "seq command" do
    test "seq generates sequence" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 3")
      assert result.stdout == "1\n2\n3\n"

      {result2, _} = JustBash.exec(bash, "seq 2 4")
      assert result2.stdout == "2\n3\n4\n"
    end

    test "seq with 3 args (start incr end)" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 1 2 7")
      assert result.stdout == "1\n3\n5\n7\n"
    end

    test "seq invalid argument" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq abc")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid argument"
    end

    test "seq missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end

    test "seq negative step" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "seq 5 -1 1")
      assert result.stdout == "5\n4\n3\n2\n1\n"
    end
  end

  describe "basename command" do
    test "basename extracts filename" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename /path/to/file.txt")
      assert result.stdout == "file.txt\n"
    end

    test "basename with suffix removal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename /path/to/file.txt .txt")
      assert result.stdout == "file\n"
    end

    test "basename missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "basename")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end
  end

  describe "dirname command" do
    test "dirname extracts directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname /path/to/file.txt")
      assert result.stdout == "/path/to\n"
    end

    test "dirname missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end

    test "dirname with nested path" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "dirname /a/b/c/d.txt")
      assert result.stdout == "/a/b/c\n"
    end
  end

  describe "env command" do
    test "env prints all environment variables" do
      bash = JustBash.new(env: %{"FOO" => "bar", "BAZ" => "qux"})
      {result, _} = JustBash.exec(bash, "env")
      assert result.stdout =~ "FOO=bar"
      assert result.stdout =~ "BAZ=qux"
      assert result.exit_code == 0
    end

    test "env includes default environment variables" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "env")
      assert result.stdout =~ "HOME=/home/user"
      assert result.stdout =~ "PATH=/bin:/usr/bin"
    end

    test "env with -i starts with empty environment" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, _} = JustBash.exec(bash, "env -i")
      assert result.stdout == ""
    end

    test "env command receives FOO=bar as argument" do
      bash = JustBash.new()
      {result, _} = Env.execute(bash, ["FOO=bar"], "")
      assert result.stdout =~ "FOO=bar"
    end

    test "env command with -i and NAME=VALUE as argument" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, _} = Env.execute(bash, ["-i", "BAZ=qux"], "")
      assert result.stdout == "BAZ=qux\n"
      refute result.stdout =~ "FOO"
    end
  end

  describe "printenv command" do
    test "printenv prints all environment variables without args" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, _} = JustBash.exec(bash, "printenv")
      assert result.stdout =~ "FOO=bar"
      assert result.exit_code == 0
    end

    test "printenv prints specific variable value" do
      bash = JustBash.new(env: %{"FOO" => "bar", "BAZ" => "qux"})
      {result, _} = JustBash.exec(bash, "printenv FOO")
      assert result.stdout == "bar\n"
      assert result.exit_code == 0
    end

    test "printenv prints multiple variable values" do
      bash = JustBash.new(env: %{"FOO" => "bar", "BAZ" => "qux"})
      {result, _} = JustBash.exec(bash, "printenv FOO BAZ")
      assert result.stdout == "bar\nqux\n"
    end

    test "printenv returns exit code 1 for missing variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printenv NONEXISTENT")
      assert result.exit_code == 1
    end
  end

  describe "which command" do
    test "which finds command in PATH" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which ls")
      assert result.stdout == "/bin/ls\n"
      assert result.exit_code == 0
    end

    test "which finds multiple commands" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which ls cat")
      assert result.stdout == "/bin/ls\n/bin/cat\n"
      assert result.exit_code == 0
    end

    test "which returns exit 1 for nonexistent command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which nonexistent")
      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "which returns exit 1 if any command not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which ls nonexistent cat")
      assert result.stdout == "/bin/ls\n/bin/cat\n"
      assert result.exit_code == 1
    end

    test "which with -s for silent mode" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -s ls")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "which returns exit 1 with -s for nonexistent" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -s nonexistent")
      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "which with -a to show all matches" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -a ls")
      assert result.stdout =~ "/bin/ls"
      assert result.exit_code == 0
    end

    test "which returns exit 1 with no arguments" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which")
      assert result.stdout == ""
      assert result.exit_code == 1
    end

    test "which supports combined -as flags" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which -as ls")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "which reports builtins as shell built-in command" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which echo")
      assert result.stdout == "echo: shell built-in command\n"
      assert result.exit_code == 0
    end

    test "which reports cd as builtin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which cd")
      assert result.stdout == "cd: shell built-in command\n"
      assert result.exit_code == 0
    end

    test "which reports external commands with path and builtins correctly" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "which ls echo grep")
      assert result.stdout == "/bin/ls\necho: shell built-in command\n/bin/grep\n"
      assert result.exit_code == 0
    end
  end

  describe "type command" do
    test "type identifies builtins" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "type echo")
      assert result.stdout == "echo is a shell builtin\n"
      assert result.exit_code == 0
    end

    test "type identifies external commands with path" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "type grep")
      assert result.stdout == "grep is /bin/grep\n"
      assert result.exit_code == 0
    end

    test "type identifies shell functions" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "myfunc() { echo hi; }\ntype myfunc")
      assert result.stdout == "myfunc is a function\n"
      assert result.exit_code == 0
    end

    test "type returns error for unknown commands" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "type nonexistent")
      assert result.stderr =~ "not found"
      assert result.exit_code == 1
    end

    test "type handles multiple arguments" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "type echo ls")
      assert result.stdout =~ "echo is a shell builtin"
      assert result.stdout =~ "ls is /bin/ls"
      assert result.exit_code == 0
    end
  end

  describe "hostname command" do
    test "hostname returns localhost" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "hostname")
      assert result.stdout == "localhost\n"
      assert result.exit_code == 0
    end
  end

  describe "tee command" do
    test "tee passes through stdin to stdout" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | tee")
      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end

    test "tee writes to file and stdout" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "echo hello | tee /home/user/output.txt")
      assert result.stdout == "hello\n"
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /home/user/output.txt")
      assert cat_result.stdout == "hello\n"
    end

    test "tee writes to multiple files" do
      bash = JustBash.new()

      {result, new_bash} =
        JustBash.exec(bash, "echo hello | tee /home/user/file1.txt /home/user/file2.txt")

      assert result.stdout == "hello\n"

      {cat1, _} = JustBash.exec(new_bash, "cat /home/user/file1.txt")
      {cat2, _} = JustBash.exec(new_bash, "cat /home/user/file2.txt")
      assert cat1.stdout == "hello\n"
      assert cat2.stdout == "hello\n"
    end

    test "tee with -a appends to file" do
      bash = JustBash.new(files: %{"/test.txt" => "existing\n"})
      {result, new_bash} = JustBash.exec(bash, "echo appended | tee -a /test.txt")
      assert result.stdout == "appended\n"

      {cat_result, _} = JustBash.exec(new_bash, "cat /test.txt")
      assert cat_result.stdout == "existing\nappended\n"
    end

    test "tee with --append flag appends to file" do
      bash = JustBash.new(files: %{"/test.txt" => "existing\n"})
      {result, new_bash} = JustBash.exec(bash, "echo appended | tee --append /test.txt")
      assert result.stdout == "appended\n"

      {cat_result, _} = JustBash.exec(new_bash, "cat /test.txt")
      assert cat_result.stdout == "existing\nappended\n"
    end

    test "tee creates file if it doesn't exist" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "echo new | tee /home/user/new.txt")
      assert result.stdout == "new\n"
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /home/user/new.txt")
      assert cat_result.stdout == "new\n"
    end

    test "tee fails if parent directory doesn't exist" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo test | tee /nonexistent/file.txt")
      assert result.stderr =~ "No such file or directory"
      assert result.exit_code == 1
      assert result.stdout == "test\n"
    end

    test "tee with empty stdin" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "echo -n '' | tee /home/user/empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /home/user/empty.txt")
      assert cat_result.stdout == ""
    end
  end

  describe "read command" do
    test "read stores in variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello | read x; echo $x")
      assert result.stdout == "hello\n"
    end

    test "read defaults to REPLY" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo world | read; echo $REPLY")
      assert result.stdout == "world\n"
    end

    test "read with empty stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | read x; echo \"got:$x:\"")
      assert result.stdout == "got::\n"
    end

    test "read splits into multiple variables on default IFS" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello world' | read a b; echo \"$a:$b\"")
      assert result.stdout == "hello:world\n"
    end

    test "read splits into multiple variables with remainder in last" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "echo 'one two three four' | read a b c; echo \"$a|$b|$c\"")

      assert result.stdout == "one|two|three four\n"
    end

    test "read splits on custom IFS" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "echo 'a,b,c' | IFS=, read x y z; echo \"$x|$y|$z\"")

      assert result.stdout == "a|b|c\n"
    end

    test "read with fewer fields than variables sets extras to empty" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'hello' | read a b; echo \"$a|$b\"")
      assert result.stdout == "hello|\n"
    end

    test "read with IFS in while loop for CSV processing" do
      bash = JustBash.new(files: %{"/data.csv" => "id,name,age\n1,Alice,30\n2,Bob,25\n"})

      script = """
      sed '1d' /data.csv | while IFS=, read -r id name age; do
        echo "$id:$name:$age"
      done
      """

      {result, _} = JustBash.exec(bash, script)
      assert result.stdout == "1:Alice:30\n2:Bob:25\n"
    end
  end

  describe "sleep command" do
    test "sleep accepts argument" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "sleep 1")
      assert result.exit_code == 0
    end
  end

  describe "exit command" do
    test "exit sets exit code" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "exit 42")
      assert result.exit_code == 42
    end

    test "exit with no arg defaults to 0" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "exit")
      assert result.exit_code == 0
    end

    test "exit with invalid arg defaults to 1" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "exit abc")
      assert result.exit_code == 1
    end
  end

  describe "xargs command" do
    test "xargs executes echo by default" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | xargs")
      assert result.stdout == "a b c\n"
      assert result.exit_code == 0
    end

    test "xargs executes specified command" do
      bash = JustBash.new(files: %{"/file1.txt" => "content1", "/file2.txt" => "content2"})
      {result, _} = JustBash.exec(bash, "echo '/file1.txt /file2.txt' | xargs cat")
      assert result.stdout == "content1content2"
    end

    test "xargs handles empty input" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | xargs")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "xargs with -n 1 batches one at a time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | xargs -n 1 echo")
      assert result.stdout == "a\nb\nc\n"
    end

    test "xargs with -n 2 batches two at a time" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c d' | xargs -n 2 echo")
      assert result.stdout == "a b\nc d\n"
    end

    test "xargs with -n handles partial last batch" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | xargs -n 2 echo")
      assert result.stdout == "a b\nc\n"
    end

    test "xargs with -I replaces placeholder" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -e 'a\\nb\\nc' | xargs -I % echo file-%")
      assert result.stdout == "file-a\nfile-b\nfile-c\n"
    end

    test "xargs with -I replaces multiple occurrences" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'x' | xargs -I % echo %-%")
      assert result.stdout == "x-x\n"
    end

    test "xargs with -t verbose mode prints commands" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'x y' | xargs -t echo")
      assert result.stdout == "x y\n"
      assert result.stderr == "echo x y\n"
    end

    test "xargs with -r does not run when empty" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | xargs -r echo nonempty")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "xargs propagates command failure exit code" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'missing.txt' | xargs cat")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "xargs with --help shows help" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "xargs --help")
      assert result.stdout =~ "xargs"
      assert result.stdout =~ "-I"
      assert result.stdout =~ "-n"
      assert result.exit_code == 0
    end

    test "xargs with file operations" do
      bash = JustBash.new(files: %{"/src/a.txt" => "content-a", "/src/b.txt" => "content-b"})
      {result, _} = JustBash.exec(bash, "echo -e '/src/a.txt\\n/src/b.txt' | xargs -I % cat %")
      assert result.stdout == "content-acontent-b"
    end

    test "xargs handles find | xargs rm pattern" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/file1.tmp" => "temp1",
            "/tmp/file2.tmp" => "temp2",
            "/keep/file.txt" => "keep"
          }
        )

      {_, bash} = JustBash.exec(bash, "echo '/tmp/file1.tmp /tmp/file2.tmp' | xargs rm")
      {result, _} = JustBash.exec(bash, "cat /tmp/file1.tmp")
      assert result.exit_code == 1

      {result, _} = JustBash.exec(bash, "cat /keep/file.txt")
      assert result.stdout == "keep"
    end
  end
end
