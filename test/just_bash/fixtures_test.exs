defmodule JustBash.FixturesTest do
  @moduledoc """
  Locks down the fixture corpus content-addressing.

  The digest is a compatibility surface, not an implementation detail: changing it
  orphans all 968 recorded expectations at once. The first describe block pins the
  recipe against values taken from the committed corpus, so an accidental change
  to canonicalization fails here rather than as a wall of unexplained fixture
  failures.
  """

  use ExUnit.Case, async: true

  doctest JustBash.Fixtures

  alias JustBash.Fixtures

  describe "content_hash/2 recipe" do
    test "reproduces hashes committed in the corpus" do
      # Taken verbatim from test/fixtures/bash_cases/. If these change, every
      # recorded expectation must be re-recorded — see Fixtures @hash_version.
      assert Fixtures.content_hash("echo 'hello world' | wc") == "d34a7800e7f5b693"
      assert Fixtures.content_hash("echo 'hello' | wc") == "722ef365ed6f83e7"
    end

    test "an absent files map hashes the same as an empty one" do
      assert Fixtures.content_hash("echo hi") == Fixtures.content_hash("echo hi", %{})
    end

    test "distinct scripts hash differently" do
      refute Fixtures.content_hash("echo a") == Fixtures.content_hash("echo b")
    end

    test "seeded files participate in the hash" do
      refute Fixtures.content_hash("cat f", %{"f" => "a"}) ==
               Fixtures.content_hash("cat f", %{"f" => "b"})
    end

    test "files key order does not affect the hash" do
      # Map literals with the same pairs are equal, so build the two orders as
      # lists to prove the encoder sorts rather than relying on iteration order.
      forward = Enum.into([{"a", "1"}, {"b", "2"}], %{})
      reverse = Enum.into([{"b", "2"}, {"a", "1"}], %{})

      assert Fixtures.content_hash("cat", forward) == Fixtures.content_hash("cat", reverse)
    end

    test "non-ASCII is canonicalized as raw UTF-8, not escaped" do
      # The corpus contains one non-ASCII case, and it pins this choice: an
      # encoder that emitted \\uXXXX escapes would produce a different digest.
      assert Fixtures.canonical("echo é", %{}) =~ "é"
      refute Fixtures.canonical("echo é", %{}) =~ "u00e9"
    end

    test "is 16 lowercase hex characters" do
      hash = Fixtures.content_hash("echo hi")

      assert String.length(hash) == 16
      assert hash =~ ~r/^[0-9a-f]{16}$/
    end
  end

  describe "canonical/2" do
    test "emits files before script, compactly" do
      assert Fixtures.canonical("echo hi", %{}) == ~s({"files":{},"script":"echo hi"})
    end

    test "emits sorted, compact file entries" do
      assert Fixtures.canonical("cat", %{"b" => "2", "a" => "1"}) ==
               ~s({"files":{"a":"1","b":"2"},"script":"cat"})
    end
  end

  describe "hash_case/1" do
    test "tolerates an absent files key" do
      assert Fixtures.hash_case(%{"script" => "echo hi"}) == Fixtures.content_hash("echo hi")
    end

    test "tolerates a null files value" do
      assert Fixtures.hash_case(%{"script" => "echo hi", "files" => nil}) ==
               Fixtures.content_hash("echo hi")
    end

    test "ignores fields that are not recording inputs" do
      # Renaming a case, or widening what it tolerates, must not orphan a
      # recording that is still byte-for-byte correct.
      bare = %{"script" => "echo hi"}
      decorated = Map.merge(bare, %{"name" => "renamed", "opts" => %{"ignore_stderr" => true}})

      assert Fixtures.hash_case(bare) == Fixtures.hash_case(decorated)
    end
  end

  describe "validate/2" do
    setup do
      test_case = %{"name" => "a case", "script" => "echo hi"}
      %{case: Map.put(test_case, "content_hash", Fixtures.hash_case(test_case))}
    end

    test "a sound suite has no problems", %{case: test_case} do
      recording = %{"content_hash" => test_case["content_hash"], "stdout" => "hi\n"}

      assert Fixtures.validate([test_case], [recording]) == []
    end

    test "detects a hash left behind by an edited script", %{case: test_case} do
      edited = %{test_case | "script" => "echo changed"}
      recording = %{"content_hash" => test_case["content_hash"]}

      problems = Fixtures.validate([edited], [recording])

      assert [{:stale_hash, "a case", stored, computed}] =
               Enum.filter(problems, &match?({:stale_hash, _, _, _}, &1))

      assert stored == test_case["content_hash"]
      assert computed == Fixtures.hash_case(edited)

      # The recording the stale hash pointed at is now unclaimed. Both facts are
      # reported: the edit is the cause, the orphan is the evidence.
      assert {:orphan_recording, stored} in problems
    end

    test "detects an absent hash as stale", %{case: test_case} do
      bare = Map.delete(test_case, "content_hash")

      assert [{:stale_hash, "a case", nil, _computed}] = Fixtures.validate([bare], [])
    end

    test "detects a case with no recording", %{case: test_case} do
      assert [{:missing_recording, "a case", hash}] = Fixtures.validate([test_case], [])
      assert hash == test_case["content_hash"]
    end

    test "detects a recording no live case claims", %{case: test_case} do
      recording = %{"content_hash" => test_case["content_hash"]}
      orphan = %{"content_hash" => "0000000000000000"}

      assert [{:orphan_recording, "0000000000000000"}] =
               Fixtures.validate([test_case], [recording, orphan])
    end

    test "accepts two cases sharing a hash when their inputs are identical", %{case: test_case} do
      # The corpus contains such a pair, differing only in name.
      twin = %{test_case | "name" => "same script, different name"}
      recording = %{"content_hash" => test_case["content_hash"]}

      assert Fixtures.validate([test_case, twin], [recording]) == []
    end

    test "reports every problem rather than stopping at the first" do
      stale = %{"name" => "stale", "script" => "echo a", "content_hash" => "dead000000000000"}
      missing = %{"name" => "missing", "script" => "echo b"}
      missing = Map.put(missing, "content_hash", Fixtures.hash_case(missing))

      problems = Fixtures.validate([stale, missing], [])

      assert length(problems) == 2
      assert Enum.any?(problems, &match?({:stale_hash, "stale", _, _}, &1))
      assert Enum.any?(problems, &match?({:missing_recording, "missing", _}, &1))
    end
  end

  describe "describe/1" do
    test "a stale hash explains the consequence, not just the mismatch" do
      message = Fixtures.describe({:stale_hash, "a case", "aaa", "bbb"})

      assert message =~ "a case"
      assert message =~ "aaa"
      assert message =~ "bbb"
      assert message =~ "different script"
    end

    test "an absent stored hash reads as none rather than empty" do
      assert Fixtures.describe({:stale_hash, "a case", nil, "bbb"}) =~ "(none)"
    end

    test "names every case involved in a collision" do
      message = Fixtures.describe({:hash_collision, "abc", ["first", "second"]})

      assert message =~ "abc"
      assert message =~ "first"
      assert message =~ "second"
    end
  end

  describe "the committed corpus" do
    @cases_dir Path.expand("../fixtures/bash_cases", __DIR__)
    @expected_dir Path.expand("../fixtures/bash_expected", __DIR__)

    test "every suite is sound" do
      # JustBash.FixtureTest raises at compile time on the two fatal problems.
      # This asserts the weaker ones too, so an orphaned recording is visible as
      # a normal test failure rather than accumulating unnoticed.
      problems =
        @cases_dir
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.flat_map(fn case_file ->
          suite = Path.basename(case_file, ".json")
          expected_file = Path.join(@expected_dir, "#{suite}.json")

          cases = case_file |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

          results =
            case File.read(expected_file) do
              {:ok, body} -> body |> Jason.decode!() |> Map.get("results", [])
              {:error, :enoent} -> []
            end

          Enum.map(Fixtures.validate(cases, results), &"#{suite}: #{Fixtures.describe(&1)}")
        end)

      assert problems == [],
             "fixture corpus integrity problems:\n" <> Enum.join(problems, "\n")
    end
  end
end
