defmodule JustBash.Eval.Commands.KVTest do
  use ExUnit.Case, async: true

  alias JustBash.Eval.Commands.KV

  defp new_bash do
    JustBash.new(commands: %{"kv" => KV})
  end

  describe "kv set and get" do
    test "set a key and retrieve it" do
      bash = new_bash()
      {result, bash} = JustBash.exec(bash, "kv set name Alice")
      assert result.exit_code == 0

      {result, _} = JustBash.exec(bash, "kv get name")
      assert result.exit_code == 0
      assert result.stdout == "Alice\n"
    end

    test "set overwrites existing key" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set color red")
      {_, bash} = JustBash.exec(bash, "kv set color blue")

      {result, _} = JustBash.exec(bash, "kv get color")
      assert result.stdout == "blue\n"
    end

    test "set with multi-word value" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set greeting hello world")

      {result, _} = JustBash.exec(bash, "kv get greeting")
      assert result.stdout == "hello world\n"
    end

    test "get nonexistent key returns exit 1" do
      bash = new_bash()

      {result, _} = JustBash.exec(bash, "kv get missing")
      assert result.exit_code == 1
      assert result.stderr =~ "not found"
    end
  end

  describe "kv delete" do
    test "delete removes key" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set tmp val")
      {result, bash} = JustBash.exec(bash, "kv delete tmp")
      assert result.exit_code == 0

      {result, _} = JustBash.exec(bash, "kv get tmp")
      assert result.exit_code == 1
    end

    test "delete nonexistent key returns exit 1" do
      bash = new_bash()

      {result, _} = JustBash.exec(bash, "kv delete ghost")
      assert result.exit_code == 1
      assert result.stderr =~ "not found"
    end
  end

  describe "kv list" do
    test "list returns sorted keys" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set zebra z")
      {_, bash} = JustBash.exec(bash, "kv set apple a")
      {_, bash} = JustBash.exec(bash, "kv set mango m")

      {result, _} = JustBash.exec(bash, "kv list")
      assert result.exit_code == 0
      assert result.stdout == "apple\nmango\nzebra\n"
    end

    test "list on empty store returns empty" do
      bash = new_bash()

      {result, _} = JustBash.exec(bash, "kv list")
      assert result.exit_code == 0
      assert result.stdout == ""
    end
  end

  describe "kv dump" do
    test "dump returns sorted key=value pairs" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set port 3000")
      {_, bash} = JustBash.exec(bash, "kv set host localhost")
      {_, bash} = JustBash.exec(bash, "kv set db mydb")

      {result, _} = JustBash.exec(bash, "kv dump")
      assert result.exit_code == 0
      assert result.stdout == "db=mydb\nhost=localhost\nport=3000\n"
    end
  end

  describe "kv count" do
    test "count returns number of keys" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set a 1")
      {_, bash} = JustBash.exec(bash, "kv set b 2")
      {_, bash} = JustBash.exec(bash, "kv set c 3")

      {result, _} = JustBash.exec(bash, "kv count")
      assert result.exit_code == 0
      assert result.stdout == "3\n"
    end
  end

  describe "kv help" do
    test "--help shows usage" do
      bash = new_bash()

      {result, _} = JustBash.exec(bash, "kv --help")
      assert result.exit_code == 0
      assert result.stdout =~ "kv set"
      assert result.stdout =~ "kv get"
      assert result.stdout =~ "kv list"
      assert result.stdout =~ "kv dump"
    end

    test "no args shows help" do
      bash = new_bash()

      {result, _} = JustBash.exec(bash, "kv")
      assert result.exit_code == 0
      assert result.stdout =~ "kv set"
    end
  end

  describe "kv unknown subcommand" do
    test "returns error" do
      bash = new_bash()

      {result, _} = JustBash.exec(bash, "kv frobnicate")
      assert result.exit_code == 1
      assert result.stderr =~ "unknown subcommand"
    end
  end

  describe "kv in pipelines" do
    test "get output can be piped" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set msg hello")

      {result, _} = JustBash.exec(bash, "kv get msg | tr 'a-z' 'A-Z'")
      assert result.stdout == "HELLO\n"
    end

    test "dump output can be piped to grep" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set db_host localhost")
      {_, bash} = JustBash.exec(bash, "kv set db_port 5432")
      {_, bash} = JustBash.exec(bash, "kv set cache_host redis")

      {result, _} = JustBash.exec(bash, "kv dump | grep '^db_'")
      assert result.exit_code == 0
      assert result.stdout == "db_host=localhost\ndb_port=5432\n"
    end
  end

  describe "kv with command substitution" do
    test "get in command substitution" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set name Bob")

      {result, _} = JustBash.exec(bash, ~s|echo "Hello, $(kv get name)"|)
      assert result.stdout == "Hello, Bob\n"
    end
  end
end
