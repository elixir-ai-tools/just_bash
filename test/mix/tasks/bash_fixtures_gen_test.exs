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

  describe "flags matrix" do
    test "probes every Registry command with both flags" do
      alias JustBash.Commands.Registry

      cases = Gen.cases_for("flags")
      names = Enum.map(cases, & &1["name"])

      assert length(cases) == length(Registry.list()) * 2

      for cmd <- Registry.list(), flag <- ["--jb-not-a-flag", "-Z"] do
        assert Enum.any?(names, &(&1 == "flags matrix: #{cmd} #{flag}")),
               "missing #{cmd} #{flag}"
      end
    end

    test "classifies every Registry name with a reason, never a silent omit" do
      alias JustBash.Commands.Registry

      classified = Gen.flags_classifications()

      assert Map.keys(classified) |> Enum.sort() == Enum.sort(Registry.list())

      Enum.each(classified, fn {name, reason} ->
        assert is_binary(reason), "#{name} has no reason"
        assert String.length(reason) > 10, "#{name} reason is too short: #{inspect(reason)}"
      end)
    end

    test "records operand and GNU -Z exceptions instead of omitting them" do
      names = Gen.cases_for("flags") |> Enum.map(& &1["name"])
      cases = Gen.cases_for("flags")

      assert Enum.any?(names, &(&1 == "flags matrix: echo -Z"))
      assert Enum.any?(names, &(&1 == "flags matrix: echo --jb-not-a-flag"))
      assert Enum.any?(names, &(&1 == "flags matrix: test -Z"))
      assert Enum.any?(names, &(&1 == "flags matrix: ls -Z"))
      assert Enum.any?(names, &(&1 == "flags matrix: markdown --jb-not-a-flag"))

      ls_z = Enum.find(cases, &(&1["name"] == "flags matrix: ls -Z"))
      assert ls_z["script"] =~ "ls -Z"
      assert ls_z["script"] =~ "/tmp/jb_flags_ls"
    end

    test "every case hashes from its script, not its name or gap" do
      cases = Gen.cases_for("flags")

      Enum.each(cases, fn test_case ->
        assert test_case["content_hash"] == JustBash.Fixtures.hash_case(test_case)
      end)
    end

    test "known_gap lives in opts and does not change the digest" do
      cases = Gen.cases_for("flags")
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

  describe "seto matrix" do
    test "enumerates every POSIX and bash set -o name, not a sample" do
      cases = Gen.cases_for("seto")
      names = Enum.map(cases, & &1["name"])

      posix = Gen.seto_posix()
      bash_extra = Gen.seto_bash()
      unknown = Gen.seto_unknown()

      assert posix ++ bash_extra == Enum.uniq(posix ++ bash_extra)
      assert length(posix) + length(bash_extra) == 27
      assert length(cases) == (length(posix) + length(bash_extra) + length(unknown)) * 2

      for opt <- posix ++ bash_extra ++ unknown, sign <- ["-o", "+o"] do
        assert Enum.any?(names, &(&1 == "seto matrix: #{sign} #{opt}")),
               "missing #{sign} #{opt}"
      end
    end

    test "covers both -o and +o so enable vs disable cannot hide" do
      names = Gen.cases_for("seto") |> Enum.map(& &1["name"])

      assert Enum.any?(names, &(&1 == "seto matrix: -o errexit"))
      assert Enum.any?(names, &(&1 == "seto matrix: +o errexit"))
      assert Enum.any?(names, &(&1 == "seto matrix: -o pipefail"))
      assert Enum.any?(names, &(&1 == "seto matrix: +o pipefail"))
      assert Enum.any?(names, &(&1 == "seto matrix: -o noglob"))
      assert Enum.any?(names, &(&1 == "seto matrix: +o noglob"))
    end

    test "every Set.option_names/0 name is in the alphabet and generated unmarked" do
      alias JustBash.Commands.Set

      supported = Set.option_names()
      alphabet = Gen.seto_posix() ++ Gen.seto_bash()
      cases = Gen.cases_for("seto")

      assert Enum.sort(Gen.seto_supported()) == Enum.sort(supported)
      assert supported -- alphabet == []
      assert "errexit" in supported

      Enum.each(supported, fn name ->
        for sign <- ["-o", "+o"] do
          test_case = Enum.find(cases, &(&1["name"] == "seto matrix: #{sign} #{name}"))
          assert test_case, "missing #{sign} #{name}"
          refute get_in(test_case, ["opts", "known_gap"]), "#{sign} #{name} was marked a gap"
        end
      end)
    end

    test "records unknown and unsupported names instead of omitting them" do
      cases = Gen.cases_for("seto")
      names = Enum.map(cases, & &1["name"])

      assert Enum.any?(names, &(&1 == "seto matrix: -o not-an-option"))
      assert Enum.any?(names, &(&1 == "seto matrix: +o jb-not-an-option"))
      assert Enum.any?(names, &(&1 == "seto matrix: -o ERREXIT"))
      assert Enum.any?(names, &(&1 == "seto matrix: -o noglob"))
      assert Enum.any?(names, &(&1 == "seto matrix: -o posix"))

      noglob = Enum.find(cases, &(&1["name"] == "seto matrix: -o noglob"))
      assert noglob["opts"]["known_gap"] =~ "rejects this set -o name"

      unknown = Enum.find(cases, &(&1["name"] == "seto matrix: -o not-an-option"))
      assert unknown["opts"]["known_gap"] =~ "exits 1"
    end

    test "every case hashes from its script, not its name or gap" do
      cases = Gen.cases_for("seto")

      Enum.each(cases, fn test_case ->
        assert test_case["content_hash"] == JustBash.Fixtures.hash_case(test_case)
      end)
    end

    test "known_gap lives in opts and does not change the digest" do
      cases = Gen.cases_for("seto")
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

    test "flags --dry-run reports a count and writes nothing" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Task.rerun("bash_fixtures.gen", ["flags", "--dry-run"])
        end)

      assert output =~ ~r/flags_matrix: \d+ cases/
      refute output =~ "wrote"
    end

    test "seto --dry-run reports a count and writes nothing" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Task.rerun("bash_fixtures.gen", ["seto", "--dry-run"])
        end)

      assert output =~ ~r/seto_matrix: \d+ cases/
      refute output =~ "wrote"
    end

    test "unknown matrix is refused" do
      assert_raise Mix.Error, ~r/Unknown matrix: oils/, fn ->
        Mix.Task.rerun("bash_fixtures.gen", ["oils"])
      end
    end
  end
end
