defmodule JustBash.SecurityTest do
  use ExUnit.Case, async: true

  alias JustBash.Security
  alias JustBash.Security.Policy

  test "public helper returns the default policy" do
    assert %Policy{} = Security.default_policy()
    assert Security.default_policy().max_steps == Policy.preset(:default).max_steps
  end

  test "public helper returns the strict policy" do
    assert %Policy{} = Security.strict_policy()
    assert Security.strict_policy().max_steps < Security.default_policy().max_steps
  end

  test "public helper returns the relaxed policy" do
    assert %Policy{} = Security.relaxed_policy()
    assert Security.relaxed_policy().max_steps > Security.default_policy().max_steps
  end

  test "policy/1 accepts preset atoms" do
    for preset <- [:default, :strict, :relaxed] do
      assert %Policy{} = Security.policy(preset)
    end
  end

  test "public helper builds a policy from keyword overrides" do
    policy = Security.policy(profile: :strict, max_steps: 55)

    assert %Policy{} = policy
    assert policy.max_steps == 55
    assert policy.max_output_bytes == Policy.preset(:strict).max_output_bytes
  end

  describe "Policy helpers" do
    test "defaults/0 returns a map with all option keys" do
      defaults = Policy.defaults()
      assert is_map(defaults)

      for key <- Policy.option_keys() do
        assert Map.has_key?(defaults, key), "missing key: #{key}"
      end
    end

    test "option_keys/0 returns a list of atoms" do
      keys = Policy.option_keys()
      assert is_list(keys)
      assert length(keys) == 25
      assert Enum.all?(keys, &is_atom/1)
    end

    test "preset/1 returns maps for all profiles" do
      for profile <- [:default, :strict, :relaxed] do
        preset = Policy.preset(profile)
        assert is_map(preset)
        assert Map.keys(preset) |> Enum.sort() == Policy.option_keys() |> Enum.sort()
      end
    end

    test "strict < default < relaxed for all keys" do
      for key <- Policy.option_keys() do
        strict = Policy.preset(:strict)[key]
        default = Policy.preset(:default)[key]
        relaxed = Policy.preset(:relaxed)[key]

        assert strict <= default,
               "#{key}: strict (#{strict}) should be <= default (#{default})"

        assert default <= relaxed,
               "#{key}: default (#{default}) should be <= relaxed (#{relaxed})"
      end
    end
  end

  describe "Policy.new/1 validation" do
    test "rejects unknown option keys" do
      assert_raise ArgumentError, ~r/unknown security options.*typo_max_step/, fn ->
        Policy.new(typo_max_step: 100)
      end
    end

    test "rejects unknown keys mixed with valid ones" do
      assert_raise ArgumentError, ~r/unknown security options/, fn ->
        Policy.new(max_steps: 100, bogus: 42)
      end
    end

    test "rejects zero values" do
      assert_raise ArgumentError, ~r/must be positive integers/, fn ->
        Policy.new(max_steps: 0)
      end
    end

    test "rejects negative values" do
      assert_raise ArgumentError, ~r/must be positive integers/, fn ->
        Policy.new(max_output_bytes: -1)
      end
    end

    test "rejects non-integer values" do
      assert_raise ArgumentError, ~r/must be positive integers/, fn ->
        Policy.new(max_steps: 1.5)
      end
    end

    test "accepts valid positive integer overrides" do
      policy = Policy.new(max_steps: 500, max_output_bytes: 2000)
      assert policy.max_steps == 500
      assert policy.max_output_bytes == 2000
    end

    test "is idempotent on a Policy struct" do
      policy = Policy.new(max_steps: 42)
      assert Policy.new(policy) == policy
    end
  end
end
