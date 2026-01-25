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

  describe "jq string interpolation" do
    test "simple interpolation" do
      bash = bash_with_json(~S({"name":"alice","age":30}))
      {result, _} = JustBash.exec(bash, "jq -r '\"Hello, \\(.name)!\"' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "Hello, alice!"
    end

    test "multiple interpolations" do
      bash = bash_with_json(~S({"name":"alice","age":30}))
      {result, _} = JustBash.exec(bash, "jq -r '\"\\(.name) is \\(.age) years old\"' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "alice is 30 years old"
    end

    test "nested field interpolation" do
      bash = bash_with_json(~S({"user":{"name":"bob"}}))
      {result, _} = JustBash.exec(bash, "jq -r '\"User: \\(.user.name)\"' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "User: bob"
    end

    test "interpolation with expression" do
      bash = bash_with_json(~S({"a":2,"b":3}))
      {result, _} = JustBash.exec(bash, "jq -r '\"Sum: \\(.a + .b)\"' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "Sum: 5"
    end

    test "interpolation with null" do
      bash = bash_with_json(~S({"name":null}))
      {result, _} = JustBash.exec(bash, "jq -r '\"Value: \\(.name)\"' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "Value: null"
    end

    test "interpolation with boolean" do
      bash = bash_with_json(~S({"active":true}))
      {result, _} = JustBash.exec(bash, "jq -r '\"Active: \\(.active)\"' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "Active: true"
    end

    test "interpolation with array" do
      bash = bash_with_json(~S({"items":[1,2,3]}))
      {result, _} = JustBash.exec(bash, "jq -r '\"Items: \\(.items)\"' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "Items: [1,2,3]"
    end

    test "iterating with interpolation" do
      bash = bash_with_json(~S([{"name":"a"},{"name":"b"}]))
      {result, _} = JustBash.exec(bash, "jq -r '.[] | \"Name: \\(.name)\"' /data.json")
      assert result.exit_code == 0
      assert result.stdout =~ "Name: a"
      assert result.stdout =~ "Name: b"
    end
  end

  describe "jq format strings" do
    test "@csv with numbers" do
      bash = bash_with_json("[1,2,3]")
      {result, _} = JustBash.exec(bash, "jq -r '@csv' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "1,2,3"
    end

    test "@csv with strings" do
      bash = bash_with_json(~S(["a","b","c"]))
      {result, _} = JustBash.exec(bash, "jq -r '@csv' /data.json")
      assert result.exit_code == 0
      # jq always quotes strings in CSV output
      assert String.trim(result.stdout) == "\"a\",\"b\",\"c\""
    end

    test "@csv escapes commas in strings" do
      bash = bash_with_json(~S(["hello, world","test"]))
      {result, _} = JustBash.exec(bash, "jq -r '@csv' /data.json")
      assert result.exit_code == 0
      # jq always quotes strings in CSV output
      assert String.trim(result.stdout) == "\"hello, world\",\"test\""
    end

    test "@csv escapes quotes in strings" do
      bash = bash_with_json(~S(["say \"hello\"","test"]))
      {result, _} = JustBash.exec(bash, "jq -r '@csv' /data.json")
      assert result.exit_code == 0
      # jq always quotes strings in CSV output
      assert String.trim(result.stdout) == "\"say \"\"hello\"\"\",\"test\""
    end

    test "@csv with mixed types" do
      bash = bash_with_json(~S(["name",42,true,null]))
      {result, _} = JustBash.exec(bash, "jq -r '@csv' /data.json")
      assert result.exit_code == 0
      # jq always quotes strings in CSV output
      assert String.trim(result.stdout) == "\"name\",42,true,"
    end

    test "@tsv with strings" do
      bash = bash_with_json(~S(["a","b","c"]))
      {result, _} = JustBash.exec(bash, "jq -r '@tsv' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "a\tb\tc"
    end

    test "@tsv escapes tabs" do
      bash = bash_with_json(~S(["hello\tworld","test"]))
      {result, _} = JustBash.exec(bash, "jq -r '@tsv' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello\\tworld\ttest"
    end

    test "@json outputs JSON" do
      bash = bash_with_json(~S({"a":1}))
      {result, _} = JustBash.exec(bash, "jq -r '@json' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == ~S({"a":1})
    end

    test "@base64 encodes string" do
      bash = bash_with_json(~S("hello"))
      {result, _} = JustBash.exec(bash, "jq -r '@base64' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "aGVsbG8="
    end

    test "@base64d decodes string" do
      bash = bash_with_json(~S("aGVsbG8="))
      {result, _} = JustBash.exec(bash, "jq -r '@base64d' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello"
    end

    test "@uri encodes string" do
      bash = bash_with_json(~S("hello world"))
      {result, _} = JustBash.exec(bash, "jq -r '@uri' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello%20world"
    end

    test "@html escapes HTML entities" do
      bash = bash_with_json(~s("<b>test</b>"))
      {result, _} = JustBash.exec(bash, "jq -r '@html' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "&lt;b&gt;test&lt;/b&gt;"
    end

    test "@csv in pipeline with iteration" do
      bash = bash_with_json(~S([{"a":1,"b":2},{"a":3,"b":4}]))
      {result, _} = JustBash.exec(bash, "jq -r '.[] | [.a, .b] | @csv' /data.json")
      assert result.exit_code == 0
      lines = String.split(String.trim(result.stdout), "\n")
      assert "1,2" in lines
      assert "3,4" in lines
    end

    test "header row with @csv" do
      bash = bash_with_json(~S([{"name":"alice","age":30}]))
      cmd = "jq -r '[\"name\",\"age\"], (.[] | [.name, .age]) | @csv' /data.json"
      {result, _} = JustBash.exec(bash, cmd)
      assert result.exit_code == 0
      lines = String.split(String.trim(result.stdout), "\n")
      # jq always quotes strings in CSV output
      assert "\"name\",\"age\"" in lines
      assert "\"alice\",30" in lines
    end
  end
end
