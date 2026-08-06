defmodule JustBash.FlagParserTest do
  use ExUnit.Case, async: true

  alias JustBash.FlagParser

  describe "parse/2" do
    test "parses boolean flags" do
      spec = %{boolean: [:a, :l, :v], value: [], defaults: %{a: false, l: false, v: false}}

      assert {:ok, %{a: true, l: false, v: false}, []} = FlagParser.parse(["-a"], spec)
      assert {:ok, %{a: false, l: true, v: false}, []} = FlagParser.parse(["-l"], spec)
      assert {:ok, %{a: true, l: true, v: false}, []} = FlagParser.parse(["-a", "-l"], spec)
    end

    test "parses combined boolean flags" do
      spec = %{boolean: [:a, :l, :v], value: [], defaults: %{a: false, l: false, v: false}}

      assert {:ok, %{a: true, l: true, v: false}, []} = FlagParser.parse(["-al"], spec)
      assert {:ok, %{a: true, l: true, v: false}, []} = FlagParser.parse(["-la"], spec)
      assert {:ok, %{a: true, l: true, v: true}, []} = FlagParser.parse(["-alv"], spec)
    end

    test "parses value flags" do
      spec = %{boolean: [], value: [:n, :d], integer: [:n], defaults: %{n: 10, d: nil}}

      assert {:ok, %{n: 5, d: nil}, []} = FlagParser.parse(["-n", "5"], spec)
      assert {:ok, %{n: 10, d: ","}, []} = FlagParser.parse(["-d", ","], spec)
      assert {:ok, %{n: 20, d: ":"}, []} = FlagParser.parse(["-n", "20", "-d", ":"], spec)
    end

    test "parses numeric shorthand for -n" do
      spec = %{boolean: [], value: [:n], integer: [:n], defaults: %{n: 10}}

      assert {:ok, %{n: 5}, []} = FlagParser.parse(["-5"], spec)
      assert {:ok, %{n: 20}, ["file.txt"]} = FlagParser.parse(["-20", "file.txt"], spec)
    end

    test "preserves remaining arguments" do
      spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}

      assert {:ok, %{a: true, l: false}, ["file.txt"]} =
               FlagParser.parse(["-a", "file.txt"], spec)

      assert {:ok, %{a: false, l: false}, ["foo", "bar"]} = FlagParser.parse(["foo", "bar"], spec)

      assert {:ok, %{a: true, l: true}, ["file1", "file2"]} =
               FlagParser.parse(["-a", "file1", "-l", "file2"], spec)
    end

    test "stops parsing at --" do
      spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}

      assert {:ok, %{a: true, l: false}, ["-l", "file"]} =
               FlagParser.parse(["-a", "--", "-l", "file"], spec)

      assert {:ok, %{a: false, l: false}, ["-a", "-l"]} =
               FlagParser.parse(["--", "-a", "-l"], spec)
    end

    test "handles mixed boolean and value flags" do
      spec = %{
        boolean: [:a, :l, :r],
        value: [:n],
        integer: [:n],
        defaults: %{a: false, l: false, r: false, n: 10}
      }

      assert {:ok, %{a: true, l: true, r: false, n: 5}, ["file"]} =
               FlagParser.parse(["-al", "-n", "5", "file"], spec)
    end

    test "uses default values" do
      spec = %{boolean: [:verbose], value: [:count], defaults: %{verbose: false, count: 42}}

      assert {:ok, %{verbose: false, count: 42}, []} = FlagParser.parse([], spec)
    end

    test "handles empty arguments" do
      spec = %{boolean: [:a], value: [:n], defaults: %{a: false, n: 10}}

      assert {:ok, %{a: false, n: 10}, []} = FlagParser.parse([], spec)
    end

    test "handles single dash as argument" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {:ok, %{a: false}, ["-"]} = FlagParser.parse(["-"], spec)
    end

    test "parses sort-style flags" do
      spec = %{boolean: [:r, :u, :n], value: [], defaults: %{r: false, u: false, n: false}}

      assert {:ok, %{r: true, u: false, n: true}, []} = FlagParser.parse(["-rn"], spec)
      assert {:ok, %{r: true, u: false, n: true}, []} = FlagParser.parse(["-nr"], spec)
    end

    test "parses grep-style flags" do
      spec = %{boolean: [:i, :v], value: [], defaults: %{i: false, v: false}}

      assert {:ok, %{i: true, v: false}, ["pattern", "file"]} =
               FlagParser.parse(["-i", "pattern", "file"], spec)
    end
  end

  describe "parse/2 with a cluster containing a value flag" do
    # getopt lets a value option end a cluster of booleans: `sort -nk2` is
    # `-n -k 2`. Peeling the attached value off character 0 only made the whole
    # cluster unknown, and the diagnostic then named `k` - a flag sort has.
    defp sort_like_spec do
      %{
        boolean: [:r, :n, :u],
        value: [:t],
        multi_value: [:k],
        defaults: %{r: false, n: false, u: false, t: nil, k: []}
      }
    end

    test "a run of booleans may be followed by a value flag with an attached value" do
      assert {:ok, %{n: true, k: ["2"]}, []} = FlagParser.parse(["-nk2"], sort_like_spec())
      assert {:ok, %{r: true, t: ":"}, []} = FlagParser.parse(["-rt:"], sort_like_spec())

      assert {:ok, %{r: true, u: true, k: ["1,1n"]}, ["f"]} =
               FlagParser.parse(["-ruk1,1n", "f"], sort_like_spec())
    end

    test "a value flag that ends a cluster takes the next argument" do
      assert {:ok, %{r: true, k: ["2"]}, ["f"]} =
               FlagParser.parse(["-rk", "2", "f"], sort_like_spec())
    end

    test "a value flag that ends a cluster with nothing after it is a missing argument" do
      assert {:error, {:missing_value, "t"}} = FlagParser.parse(["-rt"], sort_like_spec())
    end

    # The offender has to be a character the spec does not describe at all.
    # Naming an implemented flag sends the caller after the wrong problem.
    test "the character named out of a cluster is one the spec does not have" do
      assert {:error, {:unknown_flag, "Q"}} = FlagParser.parse(["-nQk2"], sort_like_spec())
      assert {:error, {:unknown_flag, "Q"}} = FlagParser.parse(["-Qk2"], sort_like_spec())
    end

    # Everything after the value flag belongs to it, so a character that would
    # otherwise be unknown is just part of the argument.
    test "an unknown character inside a value flag's argument is not a flag" do
      assert {:ok, %{r: true, t: "Q"}, []} = FlagParser.parse(["-rtQ"], sort_like_spec())
    end
  end

  describe "parse/2 with a flag the spec does not describe" do
    # Demoting the flag to an operand is what made `sort -Q file` read a file
    # named `-Q`, find nothing, and exit 0 with no diagnostic.
    test "rejects an unknown flag instead of demoting it to an operand" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {:error, {:unknown_flag, "x"}} = FlagParser.parse(["-x"], spec)
      assert {:error, {:unknown_flag, "x"}} = FlagParser.parse(["-a", "-x"], spec)
    end

    test "names the offending character of a cluster, not the cluster" do
      spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}

      assert {:error, {:unknown_flag, "Q"}} = FlagParser.parse(["-alQ"], spec)
      assert {:error, {:unknown_flag, "Q"}} = FlagParser.parse(["-Qal"], spec)
    end

    test "names a long option in full" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {:error, {:unknown_flag, "--unknown"}} = FlagParser.parse(["-a", "--unknown"], spec)
    end

    # `-5` is only a count where `-n` takes one; elsewhere it is a bad option,
    # the way `sort -5` is.
    test "rejects a numeric flag when the spec has no -n" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {:error, {:unknown_flag, "5"}} = FlagParser.parse(["-5"], spec)
    end

    test "reports a value flag with nothing after it" do
      spec = %{boolean: [], value: [:d], defaults: %{d: nil}}

      assert {:error, {:missing_value, "d"}} = FlagParser.parse(["-d"], spec)
    end

    test "stops at the first bad flag" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {:error, {:unknown_flag, "x"}} = FlagParser.parse(["-x", "-y"], spec)
    end

    test "does not reject an operand after --" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {:ok, %{a: false}, ["-x"]} = FlagParser.parse(["--", "-x"], spec)
    end
  end

  describe "value coercion" do
    # Coercing every integer-looking value turned `sort -t 1` into a delimiter
    # of `1`, which String.split/2 refuses.
    test "keeps a value that is not declared :integer as a string" do
      spec = %{boolean: [], value: [:t], defaults: %{t: nil}}

      assert {:ok, %{t: "1"}, []} = FlagParser.parse(["-t", "1"], spec)
      assert {:ok, %{t: "1"}, []} = FlagParser.parse(["-t1"], spec)
    end

    test "converts a value declared :integer" do
      spec = %{boolean: [], value: [:c], integer: [:c], defaults: %{c: nil}}

      assert {:ok, %{c: 12}, []} = FlagParser.parse(["-c", "12"], spec)
      assert {:ok, %{c: 12}, []} = FlagParser.parse(["-c12"], spec)
    end

    test "leaves a non-numeric value alone even when declared :integer" do
      spec = %{boolean: [], value: [:c], integer: [:c], defaults: %{c: nil}}

      assert {:ok, %{c: "all"}, []} = FlagParser.parse(["-c", "all"], spec)
    end

    test "accumulates multi-value flags as strings" do
      spec = %{boolean: [], value: [], multi_value: [:k], defaults: %{k: []}}

      assert {:ok, %{k: ["1", "2,2n"]}, []} = FlagParser.parse(["-k", "1", "-k", "2,2n"], spec)
    end
  end

  describe "format_error/3" do
    test "words a short option the way GNU does" do
      assert FlagParser.format_error("sort", {:unknown_flag, "Q"}, "usage\n") ==
               "sort: invalid option -- 'Q'\nusage\n"
    end

    test "words a long option the way GNU does" do
      assert FlagParser.format_error("sort", {:unknown_flag, "--nope"}, "usage\n") ==
               "sort: unrecognized option '--nope'\nusage\n"
    end

    test "words a missing value the way GNU does" do
      assert FlagParser.format_error("head", {:missing_value, "n"}, "") ==
               "head: option requires an argument -- 'n'\n"

      assert FlagParser.format_error("head", {:missing_value, "--lines"}, "") ==
               "head: option '--lines' requires an argument\n"
    end
  end
end
