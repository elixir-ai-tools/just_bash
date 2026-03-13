defmodule JustBash.Shell.BashRematchTest do
  use ExUnit.Case, async: true

  describe "BASH_REMATCH" do
    test "=~ sets BASH_REMATCH[0] to the full match" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        str="hello123world"
        if [[ "$str" =~ [0-9]+ ]]; then
          echo "${BASH_REMATCH[0]}"
        fi
        """)

      assert result.stdout == "123\n"
    end

    test "=~ sets BASH_REMATCH capture groups" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        str="2024-01-15"
        if [[ "$str" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
          echo "${BASH_REMATCH[0]}"
          echo "${BASH_REMATCH[1]}"
          echo "${BASH_REMATCH[2]}"
          echo "${BASH_REMATCH[3]}"
        fi
        """)

      assert result.stdout == "2024-01-15\n2024\n01\n15\n"
    end

    test "=~ clears BASH_REMATCH on no match" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        str="hello123"
        [[ "$str" =~ ([0-9]+) ]]
        echo "before=${BASH_REMATCH[1]}"
        [[ "$str" =~ ^ZZZZZ ]]
        echo "after=${BASH_REMATCH[0]}"
        """)

      assert result.stdout == "before=123\nafter=\n"
    end

    test "=~ with no capture groups sets only BASH_REMATCH[0]" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        [[ "foobar" =~ oo.a ]]
        echo "${BASH_REMATCH[0]}"
        echo "${BASH_REMATCH[1]}"
        """)

      assert result.stdout == "ooba\n\n"
    end

    test "BASH_REMATCH persists after the conditional" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        [[ "abc123def" =~ ([a-z]+)([0-9]+) ]]
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
        """)

      assert result.stdout == "abc-123\n"
    end
  end
end
