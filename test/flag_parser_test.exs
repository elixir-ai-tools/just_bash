defmodule JustBash.FlagParserTest do
  use ExUnit.Case, async: true

  alias JustBash.FlagParser

  describe "parse/2" do
    test "parses boolean flags" do
      spec = %{boolean: [:a, :l, :v], value: [], defaults: %{a: false, l: false, v: false}}

      assert {%{a: true, l: false, v: false}, []} = FlagParser.parse(["-a"], spec)
      assert {%{a: false, l: true, v: false}, []} = FlagParser.parse(["-l"], spec)
      assert {%{a: true, l: true, v: false}, []} = FlagParser.parse(["-a", "-l"], spec)
    end

    test "parses combined boolean flags" do
      spec = %{boolean: [:a, :l, :v], value: [], defaults: %{a: false, l: false, v: false}}

      assert {%{a: true, l: true, v: false}, []} = FlagParser.parse(["-al"], spec)
      assert {%{a: true, l: true, v: false}, []} = FlagParser.parse(["-la"], spec)
      assert {%{a: true, l: true, v: true}, []} = FlagParser.parse(["-alv"], spec)
    end

    test "parses value flags" do
      spec = %{boolean: [], value: [:n, :d], defaults: %{n: 10, d: nil}}

      assert {%{n: 5, d: nil}, []} = FlagParser.parse(["-n", "5"], spec)
      assert {%{n: 10, d: ","}, []} = FlagParser.parse(["-d", ","], spec)
      assert {%{n: 20, d: ":"}, []} = FlagParser.parse(["-n", "20", "-d", ":"], spec)
    end

    test "parses numeric shorthand for -n" do
      spec = %{boolean: [], value: [:n], defaults: %{n: 10}}

      assert {%{n: 5}, []} = FlagParser.parse(["-5"], spec)
      assert {%{n: 20}, ["file.txt"]} = FlagParser.parse(["-20", "file.txt"], spec)
    end

    test "preserves remaining arguments" do
      spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}

      assert {%{a: true, l: false}, ["file.txt"]} = FlagParser.parse(["-a", "file.txt"], spec)
      assert {%{a: false, l: false}, ["foo", "bar"]} = FlagParser.parse(["foo", "bar"], spec)

      assert {%{a: true, l: true}, ["file1", "file2"]} =
               FlagParser.parse(["-a", "file1", "-l", "file2"], spec)
    end

    test "stops parsing at --" do
      spec = %{boolean: [:a, :l], value: [], defaults: %{a: false, l: false}}

      assert {%{a: true, l: false}, ["-l", "file"]} =
               FlagParser.parse(["-a", "--", "-l", "file"], spec)

      assert {%{a: false, l: false}, ["-a", "-l"]} = FlagParser.parse(["--", "-a", "-l"], spec)
    end

    test "handles unknown flags as arguments" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {%{a: false}, ["-x"]} = FlagParser.parse(["-x"], spec)
      assert {%{a: true}, ["-unknown"]} = FlagParser.parse(["-a", "-unknown"], spec)
    end

    test "handles mixed boolean and value flags" do
      spec = %{
        boolean: [:a, :l, :r],
        value: [:n],
        defaults: %{a: false, l: false, r: false, n: 10}
      }

      assert {%{a: true, l: true, r: false, n: 5}, ["file"]} =
               FlagParser.parse(["-al", "-n", "5", "file"], spec)
    end

    test "uses default values" do
      spec = %{boolean: [:verbose], value: [:count], defaults: %{verbose: false, count: 42}}

      assert {%{verbose: false, count: 42}, []} = FlagParser.parse([], spec)
    end

    test "handles empty arguments" do
      spec = %{boolean: [:a], value: [:n], defaults: %{a: false, n: 10}}

      assert {%{a: false, n: 10}, []} = FlagParser.parse([], spec)
    end

    test "handles single dash as argument" do
      spec = %{boolean: [:a], value: [], defaults: %{a: false}}

      assert {%{a: false}, ["-"]} = FlagParser.parse(["-"], spec)
    end

    test "parses sort-style flags" do
      spec = %{boolean: [:r, :u, :n], value: [], defaults: %{r: false, u: false, n: false}}

      assert {%{r: true, u: false, n: true}, []} = FlagParser.parse(["-rn"], spec)
      assert {%{r: true, u: false, n: true}, []} = FlagParser.parse(["-nr"], spec)
    end

    test "parses grep-style flags" do
      spec = %{boolean: [:i, :v], value: [], defaults: %{i: false, v: false}}

      assert {%{i: true, v: false}, ["pattern", "file"]} =
               FlagParser.parse(["-i", "pattern", "file"], spec)
    end
  end
end
