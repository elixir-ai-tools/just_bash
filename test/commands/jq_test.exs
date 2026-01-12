defmodule JustBash.Commands.JqTest do
  use ExUnit.Case, async: true

  # Helper to create bash with a JSON file
  defp bash_with_json(json) do
    JustBash.new(files: %{"/data.json" => json})
  end

  describe "jq basic operations" do
    test "identity filter" do
      bash = bash_with_json(~S({"a":1}))
      {result, _} = JustBash.exec(bash, "jq '.' /data.json")
      assert result.exit_code == 0
      assert result.stdout =~ "\"a\""
    end

    test "field access" do
      bash = bash_with_json(~S({"name":"test"}))
      {result, _} = JustBash.exec(bash, "jq '.name' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "\"test\""
    end

    test "nested field access" do
      bash = bash_with_json(~S({"user":{"name":"alice"}}))
      {result, _} = JustBash.exec(bash, "jq '.user.name' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "\"alice\""
    end

    test "array index" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq '.[1]' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "2"
    end

    test "array iterator" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq '.[]' /data.json")
      assert result.exit_code == 0
      output = String.trim(result.stdout)
      assert output =~ "1"
      assert output =~ "2"
      assert output =~ "3"
    end

    test "raw output" do
      bash = bash_with_json(~S({"name":"test"}))
      {result, _} = JustBash.exec(bash, "jq -r '.name' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "test"
    end

    test "compact output" do
      bash = bash_with_json(~S({"a": 1, "b": 2}))
      {result, _} = JustBash.exec(bash, "jq -c '.' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == ~S({"a":1,"b":2})
    end
  end

  describe "jq functions" do
    test "keys" do
      bash = bash_with_json(~S({"b":2,"a":1}))
      {result, _} = JustBash.exec(bash, "jq 'keys' /data.json")
      assert result.exit_code == 0
      assert result.stdout =~ "a"
      assert result.stdout =~ "b"
    end

    test "length" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq 'length' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "3"
    end

    test "type" do
      bash = bash_with_json("\"hello\"")
      {result, _} = JustBash.exec(bash, "jq 'type' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "\"string\""
    end

    test "map" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq 'map(. + 1)' /data.json")
      assert result.exit_code == 0
      assert result.stdout =~ "2"
      assert result.stdout =~ "3"
      assert result.stdout =~ "4"
    end

    test "select" do
      bash = bash_with_json("[1,2,3,4,5]")
      {result, _} = JustBash.exec(bash, "jq '.[] | select(. > 3)' /data.json")
      assert result.exit_code == 0
      output = String.trim(result.stdout)
      assert output =~ "4"
      assert output =~ "5"
    end

    test "sort" do
      bash = bash_with_json("[3,1,2]")
      {result, _} = JustBash.exec(bash, "jq 'sort' /data.json")
      assert result.exit_code == 0
      assert result.stdout =~ "1" and result.stdout =~ "2" and result.stdout =~ "3"
    end

    test "unique" do
      bash = bash_with_json("[1,2,1,3,2]")
      {result, _} = JustBash.exec(bash, "jq 'unique' /data.json")
      assert result.exit_code == 0
      assert result.stdout =~ "1"
      assert result.stdout =~ "2"
      assert result.stdout =~ "3"
    end

    test "add for numbers" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq 'add' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "6"
    end

    test "first and last" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq 'first' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "1"

      {result2, _} = JustBash.exec(bash, "jq 'last' /data.json")
      assert result2.exit_code == 0
      assert String.trim(result2.stdout) == "3"
    end

    test "reverse" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq 'reverse' /data.json")
      assert result.exit_code == 0
      assert result.stdout =~ "3"
    end

    test "min and max" do
      bash = bash_with_json("[3,1,2]")
      {result, _} = JustBash.exec(bash, "jq 'min' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "1"

      {result2, _} = JustBash.exec(bash, "jq 'max' /data.json")
      assert result2.exit_code == 0
      assert String.trim(result2.stdout) == "3"
    end
  end

  describe "jq comparisons and conditionals" do
    test "equality comparison" do
      bash = bash_with_json(~S({"a":1}))
      {result, _} = JustBash.exec(bash, "jq '.a == 1' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "true"
    end

    test "if-then-else" do
      bash = bash_with_json("5")

      {result, _} =
        JustBash.exec(bash, "jq 'if . > 3 then \"big\" else \"small\" end' /data.json")

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "\"big\""
    end

    test "and/or operators" do
      bash = bash_with_json("true")
      {result, _} = JustBash.exec(bash, "jq '. and false' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "false"

      {result2, _} = JustBash.exec(bash, "jq '. or false' /data.json")
      assert result2.exit_code == 0
      assert String.trim(result2.stdout) == "true"
    end

    test "not operator" do
      bash = bash_with_json("true")
      {result, _} = JustBash.exec(bash, "jq 'not' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "false"
    end
  end

  describe "jq with stdin" do
    test "jq reads from stdin via pipe" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '[1,2,3]' | jq 'length'")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "3"
    end
  end

  describe "jq file handling" do
    test "jq reads from file" do
      bash = bash_with_json(~S({"name":"test","value":42}))
      {result, _} = JustBash.exec(bash, "jq '.name' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "\"test\""
    end

    test "jq file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "jq '.' /nonexistent.json")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "jq help" do
    test "jq --help" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "jq --help")
      assert result.exit_code == 0
      assert result.stdout =~ "JSON processor"
      assert result.stdout =~ "-r, --raw-output"
    end
  end
end
