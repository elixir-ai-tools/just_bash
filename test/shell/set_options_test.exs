defmodule JustBash.SetOptionsTest do
  use ExUnit.Case, async: true

  describe "set command" do
    test "set -e enables errexit" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -e")
      assert bash.shell_opts.errexit == true
    end

    test "set +e disables errexit" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -e")
      {_, bash} = JustBash.exec(bash, "set +e")
      assert bash.shell_opts.errexit == false
    end

    test "set -u enables nounset" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -u")
      assert bash.shell_opts.nounset == true
    end

    test "set -o pipefail enables pipefail" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -o pipefail")
      assert bash.shell_opts.pipefail == true
    end

    test "set -o errexit is equivalent to set -e" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -o errexit")
      assert bash.shell_opts.errexit == true
    end

    test "set -eu enables both errexit and nounset" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -eu")
      assert bash.shell_opts.errexit == true
      assert bash.shell_opts.nounset == true
    end

    test "set -euo pipefail enables all three" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -euo pipefail")
      assert bash.shell_opts.errexit == true
      assert bash.shell_opts.nounset == true
      assert bash.shell_opts.pipefail == true
    end

    test "set with invalid option returns error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "set -z")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid option"
    end

    test "set -o with invalid option name returns error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "set -o invalid")
      assert result.exit_code == 1
      assert result.stderr =~ "invalid option name"
    end
  end

  describe "set -e (errexit)" do
    test "script stops on first failing command" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -e
        echo first
        false
        echo second
        """)

      assert result.stdout == "first\n"
      assert result.exit_code == 1
      refute result.stdout =~ "second"
    end

    test "errexit does not trigger in && chain" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -e
        false && echo "not printed"
        echo "continues"
        """)

      assert result.stdout == "continues\n"
      assert result.exit_code == 0
    end

    test "errexit does not trigger in || chain" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -e
        false || echo "fallback"
        echo "continues"
        """)

      assert result.stdout == "fallback\ncontinues\n"
      assert result.exit_code == 0
    end

    test "errexit triggers on standalone failing command" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -e
        echo before
        cat /nonexistent
        echo after
        """)

      assert result.stdout == "before\n"
      assert result.exit_code == 1
      refute result.stdout =~ "after"
    end

    test "errexit can be disabled mid-script" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -e
        echo first
        set +e
        false
        echo second
        """)

      assert result.stdout == "first\nsecond\n"
      assert result.exit_code == 0
    end
  end

  describe "set -u (nounset)" do
    test "accessing unset variable causes error" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -u
        echo $UNSET_VAR
        """)

      assert result.exit_code == 1
      assert result.stderr =~ "UNSET_VAR"
      assert result.stderr =~ "unbound variable"
    end

    test "set variables work normally" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -u
        MY_VAR=hello
        echo $MY_VAR
        """)

      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end

    test "special variables work with nounset" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -u
        echo $?
        """)

      assert result.exit_code == 0
    end

    test "default value syntax works with nounset" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -u
        echo ${UNSET:-default}
        """)

      assert result.stdout == "default\n"
      assert result.exit_code == 0
    end

    test "nounset with empty string is OK" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -u
        EMPTY=""
        echo "[$EMPTY]"
        """)

      assert result.stdout == "[]\n"
      assert result.exit_code == 0
    end
  end

  describe "set -o pipefail" do
    test "pipeline returns rightmost non-zero exit" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -o pipefail
        false | true
        echo $?
        """)

      # Without pipefail, this would be 0. With pipefail, it's 1
      assert result.stdout == "1\n"
    end

    test "pipeline returns 0 if all commands succeed" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -o pipefail
        true | true | true
        echo $?
        """)

      assert result.stdout == "0\n"
    end

    test "without pipefail, pipeline returns last command exit" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        false | true
        echo $?
        """)

      assert result.stdout == "0\n"
    end

    test "pipefail with errexit stops on pipeline failure" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -eo pipefail
        echo before
        false | true
        echo after
        """)

      assert result.stdout == "before\n"
      assert result.exit_code == 1
      refute result.stdout =~ "after"
    end
  end

  describe "combined options" do
    test "set -euo pipefail is idiomatic strict mode" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "set -euo pipefail")
      assert bash.shell_opts.errexit == true
      assert bash.shell_opts.nounset == true
      assert bash.shell_opts.pipefail == true
    end

    test "strict mode catches unset variables" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -euo pipefail
        echo $UNDEFINED
        """)

      assert result.exit_code == 1
      assert result.stderr =~ "unbound variable"
    end

    test "strict mode catches pipeline failures" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -euo pipefail
        echo before
        cat /nonexistent 2>/dev/null | true
        echo after
        """)

      assert result.stdout == "before\n"
      assert result.exit_code == 1
    end
  end
end
