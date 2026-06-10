defmodule JustBash.Eval.Commands.KVCliTest do
  use ExUnit.Case, async: true

  alias JustBash.Eval.Commands.KVCli

  defp new_bash, do: JustBash.new(commands: %{"kv" => KVCli})

  describe "behavioral parity with the hand-rolled KV" do
    test "set and get, including multi-word values" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set greeting hello world")
      {result, _} = JustBash.exec(bash, "kv get greeting")
      assert result.stdout == "hello world\n"
    end

    test "get on a missing key exits 1" do
      {result, _} = JustBash.exec(new_bash(), "kv get nope")
      assert result.exit_code == 1
      assert result.stderr =~ "not found"
    end

    test "delete removes a key" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set tmp v")
      {_, bash} = JustBash.exec(bash, "kv delete tmp")
      {result, _} = JustBash.exec(bash, "kv get tmp")
      assert result.exit_code == 1
    end

    test "list, dump, and count" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set zebra z")
      {_, bash} = JustBash.exec(bash, "kv set apple a")

      assert elem(JustBash.exec(bash, "kv list"), 0).stdout == "apple\nzebra\n"
      assert elem(JustBash.exec(bash, "kv dump"), 0).stdout == "apple=a\nzebra=z\n"
      assert elem(JustBash.exec(bash, "kv count"), 0).stdout == "2\n"
    end

    test "works in pipelines and command substitution" do
      bash = new_bash()
      {_, bash} = JustBash.exec(bash, "kv set name Bob")
      {result, _} = JustBash.exec(bash, ~s|echo "Hi, $(kv get name)"|)
      assert result.stdout == "Hi, Bob\n"
    end
  end

  describe "what the CLI layer adds for free" do
    test "auto-generated --help lists the subcommands" do
      {result, _} = JustBash.exec(new_bash(), "kv --help")
      assert result.exit_code == 0
      assert result.stdout =~ "kv - A key-value store"
      assert result.stdout =~ "set"
      assert result.stdout =~ "Store a key-value pair"
    end

    test "per-command --help shows a usage line" do
      {result, _} = JustBash.exec(new_bash(), "kv set --help")
      assert result.stdout =~ "Usage: kv set <key> <value>..."
    end

    test "unknown subcommand exits 2 with a suggestion" do
      {result, _} = JustBash.exec(new_bash(), "kv lst")
      assert result.exit_code == 2
      assert result.stderr =~ "unknown command 'lst'"
      assert result.stderr =~ "Did you mean 'list'?"
    end

    test "missing required argument exits 2 with usage" do
      {result, _} = JustBash.exec(new_bash(), "kv get")
      assert result.exit_code == 2
      assert result.stderr =~ "missing required argument: key"
      assert result.stderr =~ "Usage: kv get <key>"
    end
  end
end
