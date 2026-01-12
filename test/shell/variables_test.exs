defmodule JustBash.Shell.VariablesTest do
  use ExUnit.Case, async: true

  describe "export and unset" do
    test "export sets environment variable" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "export FOO=bar")
      assert result.exit_code == 0
      assert new_bash.env["FOO"] == "bar"
    end

    test "unset removes environment variable" do
      bash = JustBash.new(env: %{"FOO" => "bar"})
      {result, new_bash} = JustBash.exec(bash, "unset FOO")
      assert result.exit_code == 0
      refute Map.has_key?(new_bash.env, "FOO")
    end

    test "export without value inherits existing" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "FOO=bar")
      {result, _} = JustBash.exec(bash, "export FOO; echo $FOO")
      assert result.stdout == "bar\n"
    end

    test "export multiple variables" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "export A=1 B=2; echo $A$B")
      assert result.stdout == "12\n"
    end

    test "unset multiple variables" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "A=1; B=2; C=3")
      {result, _} = JustBash.exec(bash, "unset A B; echo \"$A$B$C\"")
      assert result.stdout == "3\n"
    end

    test "unset nonexistent variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "unset NONEXISTENT")
      assert result.exit_code == 0
    end
  end

  describe "variable expansion" do
    test "simple variable expansion" do
      bash = JustBash.new(env: %{"NAME" => "world"})
      {result, _} = JustBash.exec(bash, "echo hello $NAME")
      assert result.stdout == "hello world\n"
    end

    test "undefined variable expands to empty" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello$UNDEFINED")
      assert result.stdout == "hello\n"
    end

    test "single quotes prevent expansion" do
      bash = JustBash.new(env: %{"VAR" => "value"})
      {result, _} = JustBash.exec(bash, "echo '$VAR'")
      assert result.stdout == "$VAR\n"
    end

    test "double quotes preserve variable expansion" do
      bash = JustBash.new(env: %{"VAR" => "value"})
      {result, _} = JustBash.exec(bash, ~s(echo "$VAR"))
      assert result.stdout == "value\n"
    end

    test "braced variable expansion" do
      bash = JustBash.new(env: %{"NAME" => "world"})
      {result, _} = JustBash.exec(bash, "echo ${NAME}")
      assert result.stdout == "world\n"
    end

    test "default value expansion :- when unset" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ${UNSET:-default}")
      assert result.stdout == "default\n"
    end

    test "default value expansion :- when empty" do
      bash = JustBash.new(env: %{"EMPTY" => ""})
      {result, _} = JustBash.exec(bash, "echo ${EMPTY:-default}")
      assert result.stdout == "default\n"
    end

    test "default value expansion - only when unset" do
      bash = JustBash.new(env: %{"EMPTY" => ""})
      {result, _} = JustBash.exec(bash, "echo ${EMPTY-default}")
      assert result.stdout == "\n"
    end

    test "alternative value expansion :+ when set" do
      bash = JustBash.new(env: %{"SET" => "value"})
      {result, _} = JustBash.exec(bash, "echo ${SET:+alternative}")
      assert result.stdout == "alternative\n"
    end

    test "alternative value expansion :+ when unset" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ${UNSET:+alternative}")
      assert result.stdout == "\n"
    end

    test "length expansion" do
      bash = JustBash.new(env: %{"VAR" => "hello"})
      {result, _} = JustBash.exec(bash, "echo ${#VAR}")
      assert result.stdout == "5\n"
    end

    test "special parameter $?" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "true; echo $?")
      assert result.stdout == "0\n"

      {result2, _} = JustBash.exec(bash, "false; echo $?")
      assert result2.stdout == "1\n"
    end
  end

  describe "command substitution" do
    test "basic $(cmd) substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(echo hello)")
      assert result.stdout == "hello\n"
    end

    test "$(cmd) with multiple words" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(echo hello world)")
      assert result.stdout == "hello world\n"
    end

    test "nested command substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(echo $(echo nested))")
      assert result.stdout == "nested\n"
    end

    test "$(cmd) strips trailing newlines" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"x$(echo hello)y\"")
      assert result.stdout == "xhelloy\n"
    end

    test "$(cmd) with pwd" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(pwd)")
      assert result.stdout == "/home/user\n"
    end

    test "$(cmd) with variables" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "export FOO=bar")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "echo $(echo $FOO)")
      assert result2.stdout == "bar\n"
    end

    test "$(cmd) in variable assignment" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "DIR=$(pwd)")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "echo $DIR")
      assert result2.stdout == "/home/user\n"
    end

    test "backtick substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo `echo hello`")
      assert result.stdout == "hello\n"
    end

    test "$(cmd) with cat" do
      bash = JustBash.new(files: %{"/data/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "echo $(cat /data/file.txt)")
      assert result.stdout == "content\n"
    end

    test "$(cmd) preserves exit code context" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(true) && echo success")
      assert result.stdout == "\nsuccess\n"
    end
  end

  describe "arithmetic expansion" do
    test "basic arithmetic" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 + 2))")
      assert result.stdout == "3\n"
    end

    test "arithmetic with variables" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=5")
      {result, _} = JustBash.exec(bash, "echo $((x + 3))")
      assert result.stdout == "8\n"
    end

    test "arithmetic multiplication" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((3 * 4))")
      assert result.stdout == "12\n"
    end

    test "arithmetic division" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((10 / 3))")
      assert result.stdout == "3\n"
    end

    test "arithmetic modulo" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((10 % 3))")
      assert result.stdout == "1\n"
    end

    test "arithmetic comparison" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((5 > 3))")
      assert result.stdout == "1\n"

      {result2, _} = JustBash.exec(bash, "echo $((5 < 3))")
      assert result2.stdout == "0\n"
    end

    test "arithmetic in assignment" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=$((5 + 3))")
      {result, _} = JustBash.exec(bash, "echo $x")
      assert result.stdout == "8\n"
    end

    test "arithmetic increment" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=5")
      {result, _} = JustBash.exec(bash, "echo $((++x))")
      assert result.stdout == "6\n"
    end

    test "arithmetic with parentheses" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(((2 + 3) * 4))")
      assert result.stdout == "20\n"
    end

    test "arithmetic ternary operator" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 ? 10 : 20))")
      assert result.stdout == "10\n"

      {result2, _} = JustBash.exec(bash, "echo $((0 ? 10 : 20))")
      assert result2.stdout == "20\n"
    end

    test "arithmetic assignment operators" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "x=10")
      {result, _} = JustBash.exec(bash, "echo $((x += 5))")
      assert result.stdout == "15\n"
    end

    test "arithmetic bitwise operators" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((5 & 3))")
      assert result.stdout == "1\n"

      {result2, _} = JustBash.exec(bash, "echo $((5 | 3))")
      assert result2.stdout == "7\n"
    end

    test "negative numbers" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((-5 + 3))")
      assert result.stdout == "-2\n"
    end

    test "hex numbers" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((0xff))")
      assert result.stdout == "255\n"
    end

    test "octal numbers" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((010))")
      assert result.stdout == "8\n"
    end
  end
end
