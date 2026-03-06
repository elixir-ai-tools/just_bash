defmodule CustomBuiltinTest do
  use ExUnit.Case
  doctest JustBash

  defmodule HelloBuiltinModule do
    @behaviour JustBash.Commands.Command

    alias JustBash.Commands.Command

    @impl true
    def names, do: ["hello_module"]

    @impl true
    def execute(bash, args, _stdin) do
      output = "hello " <> Enum.join(args, "")
      {Command.ok(output <> "\n"), bash}
    end
  end

  defmodule CustomBuiltinRegistry do
    # without context
    def get("hello") do
      fn bash, args, _stdin ->
        output = "hello " <> Enum.join(args, "")
        {JustBash.Commands.Command.ok(output <> "\n"), bash}
      end
    end

    def get("hello_module"), do: HelloBuiltinModule
    def get(_), do: nil

    def exists?("hello"), do: true
    def exists?("hello_module"), do: true
    def exists?(_), do: false

    # with context
    def get("hello", username) do
      fn bash, _args, _stdin ->
        output = "hello #{username}"
        {JustBash.Commands.Command.ok(output <> "\n"), bash}
      end
    end

    def get(_cmd, _ctx), do: nil

    def exists?("hello", "jose"), do: true
    def exists?(_cmd, _ctx), do: false
  end

  describe "custom builtins:" do
    test "can register and execute custom builtin via function" do
      bash = JustBash.new(custom_builtin_registry: CustomBuiltinRegistry)
      {result, _} = JustBash.exec(bash, "hello world")
      assert result.stdout == "hello world\n"
    end

    test "can register and execute custom builtin via module" do
      bash = JustBash.new(custom_builtin_registry: CustomBuiltinRegistry)
      {result, _} = JustBash.exec(bash, "hello world")
      assert result.stdout == "hello world\n"
    end

    test "can find custom command with which" do
      bash = JustBash.new(custom_builtin_registry: CustomBuiltinRegistry)
      {result, _} = JustBash.exec(bash, "which hello")
      assert result.stdout == "/bin/hello\n"
    end
  end

  describe "custom builtins with context:" do
    test "can get custom builtin with more context" do
      bash = JustBash.new(custom_builtin_registry: {CustomBuiltinRegistry, "jose"})
      {result, _} = JustBash.exec(bash, "hello")
      assert result.stdout == "hello jose\n"
    end

    test "can find custom command with which and context" do
      bash = JustBash.new(custom_builtin_registry: {CustomBuiltinRegistry, "jose"})
      {result, _} = JustBash.exec(bash, "which hello")
      assert result.stdout == "/bin/hello\n"
      assert result.exit_code == 0
    end

    test "which detects method presence by context" do
      bash = JustBash.new(custom_builtin_registry: {CustomBuiltinRegistry, "stranger"})
      {result, _} = JustBash.exec(bash, "which hello")
      assert result.stdout == ""
      assert result.exit_code == 1
    end
  end
end
