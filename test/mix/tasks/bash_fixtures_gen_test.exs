defmodule Mix.Tasks.BashFixtures.GenTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.BashFixtures.Gen

  describe "printf matrix" do
    test "enumerates a finite cross product, not a sample" do
      cases = Gen.cases_for("printf")
      names = Enum.map(cases, & &1["name"])

      assert length(cases) > 200

      for conv <- ~w(s c d i u o x X f e E g G a A b q %) do
        assert Enum.any?(names, &String.contains?(&1, "conversion %#{conv}")),
               "missing conversion %#{conv}"
      end

      for flag_name <- ~w(left plus space zero hash) do
        assert Enum.any?(names, &String.contains?(&1, "flag #{flag_name}")),
               "missing flag #{flag_name}"
      end

      assert Enum.any?(names, &String.contains?(&1, "width 5"))
      assert Enum.any?(names, &String.contains?(&1, "precision 2"))
      assert Enum.any?(names, &String.contains?(&1, "star width"))
      assert Enum.any?(names, &String.contains?(&1, "recycle"))
      assert Enum.any?(names, &String.contains?(&1, "%b "))
      assert Enum.any?(names, &String.contains?(&1, "%q "))
    end

    test "uses two or more bases so padding and signs are visible" do
      names = Gen.cases_for("printf") |> Enum.map(& &1["name"])

      assert Enum.any?(names, &(&1 =~ "conversion %d (seven)"))
      assert Enum.any?(names, &(&1 =~ "conversion %d (byte)"))
      assert Enum.any?(names, &(&1 =~ "conversion %d (neg)"))
      assert Enum.any?(names, &(&1 =~ "conversion %s (hi)"))
      assert Enum.any?(names, &(&1 =~ "conversion %s (empty)"))
    end

    test "every case hashes from its script, not its name or gap" do
      cases = Gen.cases_for("printf")

      Enum.each(cases, fn test_case ->
        assert test_case["content_hash"] == JustBash.Fixtures.hash_case(test_case)
      end)
    end

    test "known_gap lives in opts and does not change the digest" do
      cases = Gen.cases_for("printf")
      gapped = Enum.filter(cases, &get_in(&1, ["opts", "known_gap"]))

      assert length(gapped) > 100
      assert length(gapped) < length(cases)

      Enum.each(gapped, fn test_case ->
        reason = test_case["opts"]["known_gap"]
        assert is_binary(reason)
        assert String.length(reason) > 10

        assert JustBash.Fixtures.hash_case(test_case) ==
                 JustBash.Fixtures.hash_case(Map.delete(test_case, "opts"))
      end)
    end
  end

  describe "test matrix" do
    test "enumerates every operator, not a sample" do
      cases = Gen.cases_for("test")
      names = Enum.map(cases, & &1["name"])

      assert length(cases) > 150

      for op <- ~w(-e -f -d -L -h -s -r -w -x -z -n -b -c -p -S -t -u -g -k -G -O -N) do
        assert Enum.any?(names, &String.contains?(&1, " #{op} ")),
               "missing unary #{op}"
      end

      for op <- ~w(= == != < > -eq -ne -lt -le -gt -ge -nt -ot -ef -a -o) do
        assert Enum.any?(names, &String.contains?(&1, " #{op} ")),
               "missing binary #{op}"
      end

      assert Enum.any?(names, &String.contains?(&1, "test ! "))
      assert Enum.any?(names, &String.contains?(&1, "test group "))
    end

    test "uses two or more bases so false-vs-missing and 10-vs-9 are visible" do
      names = Gen.cases_for("test") |> Enum.map(& &1["name"])

      assert Enum.any?(names, &(&1 =~ "test -e (regular)"))
      assert Enum.any?(names, &(&1 =~ "test -e (missing)"))
      assert Enum.any?(names, &(&1 =~ "test -L (symlink)"))
      assert Enum.any?(names, &(&1 =~ "test -L (dangling)"))
      assert Enum.any?(names, &(&1 =~ "test -z (empty)"))
      assert Enum.any?(names, &(&1 =~ "test -z (hi)"))
      assert Enum.any?(names, &(&1 =~ "test -eq (zeros)"))
      assert Enum.any?(names, &(&1 =~ "test -eq (order)"))
      assert Enum.any?(names, &(&1 =~ "test -lt (order)"))
      assert Enum.any?(names, &(&1 =~ "test < (digits)"))
    end

    test "covers both test and [ for a representative subset" do
      names = Gen.cases_for("test") |> Enum.map(& &1["name"])

      for fragment <- ["-e (regular)", "-z (empty)", "= (equal)", "-eq (zeros)", "! -z (empty)"] do
        assert Enum.any?(names, &String.contains?(&1, "test #{fragment}")),
               "missing test #{fragment}"

        assert Enum.any?(names, &String.contains?(&1, "[ #{fragment}")),
               "missing [ #{fragment}"
      end
    end

    test "every case hashes from its script, not its name or gap" do
      cases = Gen.cases_for("test")

      Enum.each(cases, fn test_case ->
        assert test_case["content_hash"] == JustBash.Fixtures.hash_case(test_case)
      end)
    end

    test "known_gap lives in opts and does not change the digest" do
      cases = Gen.cases_for("test")
      gapped = Enum.filter(cases, &get_in(&1, ["opts", "known_gap"]))

      assert length(gapped) > 10
      assert length(gapped) < length(cases)

      Enum.each(gapped, fn test_case ->
        reason = test_case["opts"]["known_gap"]
        assert is_binary(reason)
        assert String.length(reason) > 10

        assert JustBash.Fixtures.hash_case(test_case) ==
                 JustBash.Fixtures.hash_case(Map.delete(test_case, "opts"))
      end)
    end
  end

  describe "varop matrix" do
    test "enumerates every ${var op word} form, not a sample" do
      cases = Gen.cases_for("varop")
      names = Enum.map(cases, & &1["name"])

      assert length(cases) > 150

      for op <- ["-", ":-", "=", ":=", "+", ":+", "?", ":?"] do
        fragment = "${" <> "v#{op}"

        assert Enum.any?(names, &String.contains?(&1, fragment)),
               "missing word-op #{fragment}"
      end

      for op <- ["#", "##", "%", "%%"] do
        fragment = "${" <> "v#{op}"

        assert Enum.any?(names, &String.contains?(&1, fragment)),
               "missing removal #{fragment}"
      end

      assert Enum.any?(names, &String.contains?(&1, ~S|${#v}|))
      assert Enum.any?(names, &String.contains?(&1, ~S|${v:3}|))
      assert Enum.any?(names, &String.contains?(&1, ~S|${v:1:3}|))
      assert Enum.any?(names, &String.contains?(&1, ~S|${v/o/X}|))
      assert Enum.any?(names, &String.contains?(&1, ~S|${v//o/X}|))
    end

    test "uses two or more bases so prefix/suffix and offset cannot hide" do
      names = Gen.cases_for("varop") |> Enum.map(& &1["name"])

      for fragment <- [
            ~S|${v-word} (unset|,
            ~S|${v-word} (empty|,
            ~S|${v-word} (foo|,
            ~S|${v-word} (foobar|,
            ~S|${v-} (unset|,
            ~S|${v:3} (foo)|,
            ~S|${v:3} (foobar)|,
            ~S|${v#f*} (foo)|,
            ~S|${v#f*} (foobar)|,
            ~S|${v##f*} (foofoo)|,
            ~S|${v//foo/X} (foofoo)|
          ] do
        assert Enum.any?(names, &String.contains?(&1, fragment)),
               "missing #{fragment}"
      end
    end

    test "quotes expansions and is explicit about set +u vs unset" do
      cases = Gen.cases_for("varop")

      assert Enum.any?(cases, fn test_case ->
               String.contains?(test_case["script"], ~S|"[${v-word}]"|) and
                 String.contains?(test_case["script"], "set +u") and
                 String.contains?(test_case["script"], "unset v")
             end)

      assert Enum.any?(cases, fn test_case ->
               String.contains?(test_case["name"], ~S|set -u ${v-word}|) and
                 String.contains?(test_case["script"], "set -u")
             end)
    end

    test "every case hashes from its script, not its name or gap" do
      cases = Gen.cases_for("varop")

      Enum.each(cases, fn test_case ->
        assert test_case["content_hash"] == JustBash.Fixtures.hash_case(test_case)
      end)
    end

    test "known_gap lives in opts and does not change the digest" do
      cases = Gen.cases_for("varop")
      gapped = Enum.filter(cases, &get_in(&1, ["opts", "known_gap"]))

      assert length(gapped) > 10
      assert length(gapped) < length(cases)

      Enum.each(gapped, fn test_case ->
        reason = test_case["opts"]["known_gap"]
        assert is_binary(reason)
        assert String.length(reason) > 10

        assert JustBash.Fixtures.hash_case(test_case) ==
                 JustBash.Fixtures.hash_case(Map.delete(test_case, "opts"))
      end)
    end
  end

  describe "run/1" do
    test "printf --dry-run reports a count and writes nothing" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Task.rerun("bash_fixtures.gen", ["printf", "--dry-run"])
        end)

      assert output =~ ~r/printf_matrix: \d+ cases/
      refute output =~ "wrote"
    end

    test "test --dry-run reports a count and writes nothing" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Task.rerun("bash_fixtures.gen", ["test", "--dry-run"])
        end)

      assert output =~ ~r/test_matrix: \d+ cases/
      refute output =~ "wrote"
    end

    test "varop --dry-run reports a count and writes nothing" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Task.rerun("bash_fixtures.gen", ["varop", "--dry-run"])
        end)

      assert output =~ ~r/varop_matrix: \d+ cases/
      refute output =~ "wrote"
    end

    test "unknown matrix is refused" do
      assert_raise Mix.Error, ~r/Unknown matrix: oils/, fn ->
        Mix.Task.rerun("bash_fixtures.gen", ["oils"])
      end
    end
  end
end
