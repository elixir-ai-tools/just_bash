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

  describe "run/1" do
    test "printf --dry-run reports a count and writes nothing" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Task.rerun("bash_fixtures.gen", ["printf", "--dry-run"])
        end)

      assert output =~ ~r/printf_matrix: \d+ cases/
      refute output =~ "wrote"
    end

    test "unknown matrix is refused" do
      assert_raise Mix.Error, ~r/Unknown matrix: oils/, fn ->
        Mix.Task.rerun("bash_fixtures.gen", ["oils"])
      end
    end
  end
end
