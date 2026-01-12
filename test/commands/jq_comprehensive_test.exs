defmodule JustBash.Commands.JqComprehensiveTest do
  use ExUnit.Case, async: true

  # Helper to run jq on JSON data
  defp jq(json, filter, opts \\ []) do
    raw = Keyword.get(opts, :raw, false)
    compact = Keyword.get(opts, :compact, false)

    flags = []
    flags = if raw, do: ["-r" | flags], else: flags
    flags = if compact, do: ["-c" | flags], else: flags
    flag_str = Enum.join(flags, " ")

    bash = JustBash.new(files: %{"/data.json" => json})
    cmd = "jq #{flag_str} '#{filter}' /data.json"
    {result, _} = JustBash.exec(bash, cmd)
    result
  end

  defp jq_ok(json, filter, opts \\ []) do
    result = jq(json, filter, opts)
    assert result.exit_code == 0, "Expected exit 0, got #{result.exit_code}: #{result.stderr}"
    String.trim(result.stdout)
  end

  defp jq_err(json, filter) do
    result = jq(json, filter)
    assert result.exit_code != 0, "Expected error but got success: #{result.stdout}"
    result.stderr
  end

  # ============================================================================
  # IDENTITY AND BASIC ACCESS
  # ============================================================================

  describe "identity filter" do
    test "identity on null" do
      assert jq_ok("null", ".") == "null"
    end

    test "identity on boolean true" do
      assert jq_ok("true", ".") == "true"
    end

    test "identity on boolean false" do
      assert jq_ok("false", ".") == "false"
    end

    test "identity on integer" do
      assert jq_ok("42", ".") == "42"
    end

    test "identity on negative integer" do
      assert jq_ok("-42", ".") == "-42"
    end

    test "identity on float" do
      assert jq_ok("3.14159", ".") == "3.14159"
    end

    test "identity on string" do
      assert jq_ok(~S("hello"), ".") == ~S("hello")
    end

    test "identity on empty string" do
      assert jq_ok(~S(""), ".") == ~S("")
    end

    test "identity on empty array" do
      assert jq_ok("[]", ".", compact: true) == "[]"
    end

    test "identity on empty object" do
      assert jq_ok("{}", ".", compact: true) == "{}"
    end

    test "identity preserves unicode" do
      assert jq_ok(~S("日本語"), ".") == ~S("日本語")
    end

    test "identity preserves emoji" do
      assert jq_ok(~S("🎉"), ".") == ~S("🎉")
    end
  end

  describe "field access" do
    test "simple field access" do
      assert jq_ok(~S({"a":1}), ".a") == "1"
    end

    test "field with underscore" do
      assert jq_ok(~S({"foo_bar":1}), ".foo_bar") == "1"
    end

    test "field starting with underscore" do
      assert jq_ok(~S({"_private":1}), "._private") == "1"
    end

    test "missing field returns null" do
      assert jq_ok(~S({"a":1}), ".b") == "null"
    end

    test "field access on null returns null" do
      assert jq_ok("null", ".foo") == "null"
    end

    test "nested field access" do
      assert jq_ok(~S({"a":{"b":{"c":1}}}), ".a.b.c") == "1"
    end

    test "deeply nested field access" do
      json = ~S({"l1":{"l2":{"l3":{"l4":{"l5":1}}}}})
      assert jq_ok(json, ".l1.l2.l3.l4.l5") == "1"
    end

    test "field access on array fails" do
      stderr = jq_err("[1,2,3]", ".foo")
      assert stderr =~ "cannot index"
    end

    test "field with numeric value" do
      assert jq_ok(~S({"x":123}), ".x") == "123"
    end

    test "field with null value" do
      assert jq_ok(~S({"x":null}), ".x") == "null"
    end

    test "field with boolean value" do
      assert jq_ok(~S({"x":true}), ".x") == "true"
    end

    test "field with array value" do
      result = jq_ok(~S({"x":[1,2,3]}), ".x", compact: true)
      assert result == "[1,2,3]"
    end

    test "field with object value" do
      result = jq_ok(~S({"x":{"y":1}}), ".x", compact: true)
      assert result == ~S({"y":1})
    end
  end

  describe "array indexing" do
    test "first element" do
      assert jq_ok("[1,2,3]", ".[0]") == "1"
    end

    test "second element" do
      assert jq_ok("[1,2,3]", ".[1]") == "2"
    end

    test "last element with positive index" do
      assert jq_ok("[1,2,3]", ".[2]") == "3"
    end

    test "negative index -1 gets last" do
      assert jq_ok("[1,2,3]", ".[-1]") == "3"
    end

    test "negative index -2 gets second to last" do
      assert jq_ok("[1,2,3]", ".[-2]") == "2"
    end

    test "out of bounds returns null" do
      assert jq_ok("[1,2,3]", ".[10]") == "null"
    end

    test "negative out of bounds returns null" do
      assert jq_ok("[1,2,3]", ".[-10]") == "null"
    end

    test "index on empty array" do
      assert jq_ok("[]", ".[0]") == "null"
    end

    test "index on null returns null" do
      assert jq_ok("null", ".[0]") == "null"
    end

    test "nested array access" do
      assert jq_ok("[[1,2],[3,4]]", ".[0][1]") == "2"
    end

    test "mixed array and object access" do
      json = ~S([{"a":1},{"a":2}])
      assert jq_ok(json, ".[1].a") == "2"
    end
  end

  describe "array iteration" do
    test "iterate simple array" do
      result = jq_ok("[1,2,3]", ".[]")
      assert result =~ "1"
      assert result =~ "2"
      assert result =~ "3"
    end

    test "iterate empty array produces no output" do
      result = jq_ok("[]", ".[]")
      assert result == ""
    end

    test "iterate object values" do
      result = jq_ok(~S({"a":1,"b":2}), ".[]")
      assert result =~ "1"
      assert result =~ "2"
    end

    test "iterate null produces no output" do
      result = jq_ok("null", ".[]")
      assert result == ""
    end

    test "iterate nested arrays" do
      result = jq_ok("[[1,2],[3,4]]", ".[][]")
      assert result =~ "1"
      assert result =~ "4"
    end

    test "iterate then access field" do
      json = ~S([{"name":"a"},{"name":"b"}])
      result = jq_ok(json, ".[].name", raw: true)
      assert result =~ "a"
      assert result =~ "b"
    end
  end

  # ============================================================================
  # PIPES AND COMPOSITION
  # ============================================================================

  describe "pipe operator" do
    test "simple pipe" do
      assert jq_ok(~S({"a":{"b":1}}), ".a | .b") == "1"
    end

    test "multiple pipes" do
      json = ~S({"a":{"b":{"c":1}}})
      assert jq_ok(json, ".a | .b | .c") == "1"
    end

    test "pipe with function" do
      assert jq_ok("[1,2,3]", ". | length") == "3"
    end

    test "pipe iterator to function" do
      assert jq_ok("[1,2,3]", ".[] | . + 1")
      # Should produce 2, 3, 4 on separate lines
    end

    test "pipe to select" do
      result = jq_ok("[1,2,3,4,5]", ".[] | select(. > 3)")
      assert result =~ "4"
      assert result =~ "5"
      refute result =~ "1"
    end
  end

  describe "comma operator" do
    test "multiple outputs" do
      result = jq_ok(~S({"a":1,"b":2}), ".a, .b")
      lines = String.split(result, "\n")
      assert "1" in lines
      assert "2" in lines
    end

    test "comma with same field" do
      result = jq_ok(~S({"a":1}), ".a, .a")
      assert result =~ "1"
    end

    test "three values" do
      result = jq_ok(~S({"a":1,"b":2,"c":3}), ".a, .b, .c")
      assert result =~ "1"
      assert result =~ "2"
      assert result =~ "3"
    end
  end

  # ============================================================================
  # ARITHMETIC
  # ============================================================================

  describe "arithmetic operations" do
    test "addition of integers" do
      assert jq_ok("5", ". + 3") == "8"
    end

    test "addition of floats" do
      result = jq_ok("1.5", ". + 2.5")
      assert String.to_float(result) == 4.0
    end

    test "subtraction" do
      assert jq_ok("10", ". - 3") == "7"
    end

    test "multiplication" do
      assert jq_ok("6", ". * 7") == "42"
    end

    test "division" do
      result = jq_ok("10", ". / 4")
      assert String.to_float(result) == 2.5
    end

    test "modulo" do
      assert jq_ok("17", ". % 5") == "2"
    end

    test "string concatenation with +" do
      result = jq_ok(~S("hello"), ". + \" world\"", raw: true)
      assert result == "hello world"
    end

    test "array concatenation with +" do
      result = jq_ok("[1,2]", ". + [3,4]", compact: true)
      assert result == "[1,2,3,4]"
    end

    test "object merge with +" do
      result = jq_ok(~S({"a":1}), ". + {\"b\":2}", compact: true)
      assert result =~ "\"a\""
      assert result =~ "\"b\""
    end

    test "complex arithmetic expression" do
      assert jq_ok("10", "(. + 5) * 2") == "30"
    end

    test "arithmetic with field access" do
      assert jq_ok(~S({"x":10,"y":3}), ".x + .y") == "13"
    end

    test "arithmetic in map" do
      result = jq_ok("[1,2,3]", "map(. * 2)", compact: true)
      assert result == "[2,4,6]"
    end

    test "null + value returns value" do
      assert jq_ok("null", ". + 5") == "5"
    end

    test "value + null returns value" do
      assert jq_ok("5", ". + null") == "5"
    end
  end

  # ============================================================================
  # COMPARISONS AND BOOLEAN LOGIC
  # ============================================================================

  describe "comparison operators" do
    test "equal true" do
      assert jq_ok("5", ". == 5") == "true"
    end

    test "equal false" do
      assert jq_ok("5", ". == 6") == "false"
    end

    test "not equal true" do
      assert jq_ok("5", ". != 6") == "true"
    end

    test "not equal false" do
      assert jq_ok("5", ". != 5") == "false"
    end

    test "less than true" do
      assert jq_ok("5", ". < 10") == "true"
    end

    test "less than false" do
      assert jq_ok("10", ". < 5") == "false"
    end

    test "less than or equal" do
      assert jq_ok("5", ". <= 5") == "true"
      assert jq_ok("4", ". <= 5") == "true"
      assert jq_ok("6", ". <= 5") == "false"
    end

    test "greater than" do
      assert jq_ok("10", ". > 5") == "true"
      assert jq_ok("3", ". > 5") == "false"
    end

    test "greater than or equal" do
      assert jq_ok("5", ". >= 5") == "true"
      assert jq_ok("6", ". >= 5") == "true"
      assert jq_ok("4", ". >= 5") == "false"
    end

    test "string comparison" do
      assert jq_ok(~S("abc"), ". == \"abc\"") == "true"
      assert jq_ok(~S("abc"), ". == \"def\"") == "false"
    end

    test "null comparison" do
      assert jq_ok("null", ". == null") == "true"
    end

    test "compare field values" do
      assert jq_ok(~S({"a":5,"b":10}), ".a < .b") == "true"
    end
  end

  describe "boolean operators" do
    test "and - both true" do
      assert jq_ok("true", ". and true") == "true"
    end

    test "and - one false" do
      assert jq_ok("true", ". and false") == "false"
      assert jq_ok("false", ". and true") == "false"
    end

    test "or - both false" do
      assert jq_ok("false", ". or false") == "false"
    end

    test "or - one true" do
      assert jq_ok("false", ". or true") == "true"
      assert jq_ok("true", ". or false") == "true"
    end

    test "not on true" do
      assert jq_ok("true", "not") == "false"
    end

    test "not on false" do
      assert jq_ok("false", "not") == "true"
    end

    test "not on null (falsy)" do
      assert jq_ok("null", "not") == "true"
    end

    test "not on number (truthy)" do
      assert jq_ok("1", "not") == "false"
    end

    test "complex boolean expression" do
      assert jq_ok("5", "(. > 3) and (. < 10)") == "true"
    end
  end

  describe "if-then-else" do
    test "if true branch" do
      result = jq_ok("5", "if . > 3 then \"big\" else \"small\" end", raw: true)
      assert result == "big"
    end

    test "if false branch" do
      result = jq_ok("2", "if . > 3 then \"big\" else \"small\" end", raw: true)
      assert result == "small"
    end

    test "if with complex condition" do
      json = ~S({"age":25})
      result = jq_ok(json, "if .age >= 18 then \"adult\" else \"minor\" end", raw: true)
      assert result == "adult"
    end

    test "nested if" do
      result =
        jq_ok("5", "if . < 3 then \"low\" else if . < 7 then \"mid\" else \"high\" end end",
          raw: true
        )

      assert result == "mid"
    end
  end

  # ============================================================================
  # BUILT-IN FUNCTIONS
  # ============================================================================

  describe "type function" do
    test "type of null" do
      assert jq_ok("null", "type", raw: true) == "null"
    end

    test "type of boolean" do
      assert jq_ok("true", "type", raw: true) == "boolean"
    end

    test "type of number" do
      assert jq_ok("42", "type", raw: true) == "number"
    end

    test "type of string" do
      assert jq_ok(~S("hello"), "type", raw: true) == "string"
    end

    test "type of array" do
      assert jq_ok("[1,2,3]", "type", raw: true) == "array"
    end

    test "type of object" do
      assert jq_ok(~S({"a":1}), "type", raw: true) == "object"
    end
  end

  describe "length function" do
    test "length of string" do
      assert jq_ok(~S("hello"), "length") == "5"
    end

    test "length of empty string" do
      assert jq_ok(~S(""), "length") == "0"
    end

    test "length of unicode string" do
      assert jq_ok(~S("日本"), "length") == "2"
    end

    test "length of array" do
      assert jq_ok("[1,2,3,4,5]", "length") == "5"
    end

    test "length of empty array" do
      assert jq_ok("[]", "length") == "0"
    end

    test "length of object" do
      assert jq_ok(~S({"a":1,"b":2}), "length") == "2"
    end

    test "length of null" do
      assert jq_ok("null", "length") == "0"
    end
  end

  describe "keys function" do
    test "keys of object" do
      result = jq_ok(~S({"b":2,"a":1}), "keys", compact: true)
      # Keys should be sorted
      assert result == ~S(["a","b"])
    end

    test "keys of empty object" do
      assert jq_ok("{}", "keys", compact: true) == "[]"
    end

    test "keys of array returns indices" do
      assert jq_ok("[10,20,30]", "keys", compact: true) == "[0,1,2]"
    end
  end

  describe "values function" do
    test "values of object" do
      result = jq_ok(~S({"a":1,"b":2}), "values")
      assert result =~ "1"
      assert result =~ "2"
    end

    test "values of array returns elements" do
      result = jq_ok("[1,2,3]", "values", compact: true)
      assert result == "[1,2,3]"
    end
  end

  describe "map function" do
    test "map with addition" do
      assert jq_ok("[1,2,3]", "map(. + 10)", compact: true) == "[11,12,13]"
    end

    test "map with multiplication" do
      assert jq_ok("[1,2,3]", "map(. * 2)", compact: true) == "[2,4,6]"
    end

    test "map on empty array" do
      assert jq_ok("[]", "map(. + 1)", compact: true) == "[]"
    end

    test "map with field access" do
      json = ~S([{"x":1},{"x":2},{"x":3}])
      assert jq_ok(json, "map(.x)", compact: true) == "[1,2,3]"
    end

    test "map with complex expression" do
      json = ~S([{"a":1,"b":2},{"a":3,"b":4}])
      assert jq_ok(json, "map(.a + .b)", compact: true) == "[3,7]"
    end
  end

  describe "select function" do
    test "select matching" do
      result = jq_ok("[1,2,3,4,5]", ".[] | select(. > 3)")
      assert result =~ "4"
      assert result =~ "5"
      refute result =~ "1"
      refute result =~ "2"
      refute result =~ "3"
    end

    test "select none matching" do
      result = jq_ok("[1,2,3]", ".[] | select(. > 10)")
      assert result == ""
    end

    test "select all matching" do
      result = jq_ok("[1,2,3]", ".[] | select(. > 0)")
      assert result =~ "1"
      assert result =~ "2"
      assert result =~ "3"
    end

    test "select with field comparison" do
      json = ~S([{"age":25},{"age":15},{"age":30}])
      result = jq_ok(json, ".[] | select(.age >= 18)")
      assert result =~ "25"
      assert result =~ "30"
      refute result =~ "15"
    end

    test "select with equality" do
      json = ~S([{"status":"active"},{"status":"inactive"}])
      result = jq_ok(json, ".[] | select(.status == \"active\")", compact: true)
      assert result =~ "active"
      refute result =~ "inactive"
    end
  end

  describe "sort functions" do
    test "sort numbers" do
      assert jq_ok("[3,1,4,1,5,9,2,6]", "sort", compact: true) == "[1,1,2,3,4,5,6,9]"
    end

    test "sort strings" do
      json = ~S(["banana","apple","cherry"])
      result = jq_ok(json, "sort", compact: true)
      assert result == ~S(["apple","banana","cherry"])
    end

    test "sort empty array" do
      assert jq_ok("[]", "sort", compact: true) == "[]"
    end

    test "sort_by field" do
      json = ~S([{"name":"b","val":2},{"name":"a","val":1}])
      result = jq_ok(json, "sort_by(.name)", compact: true)
      # First should have name "a"
      assert String.starts_with?(result, ~S([{"name":"a"))
    end

    test "reverse" do
      assert jq_ok("[1,2,3]", "reverse", compact: true) == "[3,2,1]"
    end

    test "reverse empty" do
      assert jq_ok("[]", "reverse", compact: true) == "[]"
    end
  end

  describe "unique functions" do
    test "unique numbers" do
      assert jq_ok("[1,2,1,3,2,1]", "unique", compact: true) == "[1,2,3]"
    end

    test "unique strings" do
      json = ~S(["a","b","a","c","b"])
      result = jq_ok(json, "unique", compact: true)
      assert result == ~S(["a","b","c"])
    end

    test "unique empty" do
      assert jq_ok("[]", "unique", compact: true) == "[]"
    end

    test "unique_by field" do
      json = ~S([{"id":1,"name":"a"},{"id":1,"name":"b"},{"id":2,"name":"c"}])
      result = jq_ok(json, "unique_by(.id)")
      # Should have 2 elements
      assert result =~ "\"id\": 1"
      assert result =~ "\"id\": 2"
    end
  end

  describe "min/max functions" do
    test "min of numbers" do
      assert jq_ok("[5,2,8,1,9]", "min") == "1"
    end

    test "max of numbers" do
      assert jq_ok("[5,2,8,1,9]", "max") == "9"
    end

    test "min of empty array" do
      assert jq_ok("[]", "min") == "null"
    end

    test "max of empty array" do
      assert jq_ok("[]", "max") == "null"
    end

    test "min_by field" do
      json = ~S([{"val":5},{"val":2},{"val":8}])
      result = jq_ok(json, "min_by(.val)", compact: true)
      assert result =~ "\"val\":2"
    end

    test "max_by field" do
      json = ~S([{"val":5},{"val":2},{"val":8}])
      result = jq_ok(json, "max_by(.val)", compact: true)
      assert result =~ "\"val\":8"
    end
  end

  describe "first/last functions" do
    test "first of array" do
      assert jq_ok("[1,2,3]", "first") == "1"
    end

    test "last of array" do
      assert jq_ok("[1,2,3]", "last") == "3"
    end

    test "first of empty array" do
      assert jq_ok("[]", "first") == "null"
    end

    test "last of empty array" do
      assert jq_ok("[]", "last") == "null"
    end
  end

  describe "add function" do
    test "add numbers" do
      assert jq_ok("[1,2,3,4]", "add") == "10"
    end

    test "add strings" do
      json = ~S(["a","b","c"])
      assert jq_ok(json, "add", raw: true) == "abc"
    end

    test "add arrays" do
      assert jq_ok("[[1,2],[3,4],[5]]", "add", compact: true) == "[1,2,3,4,5]"
    end

    test "add empty array" do
      assert jq_ok("[]", "add") == "null"
    end
  end

  describe "flatten function" do
    test "flatten nested arrays" do
      assert jq_ok("[[1,2],[3,[4,5]]]", "flatten", compact: true) == "[1,2,3,4,5]"
    end

    test "flatten with depth" do
      assert jq_ok("[[1,[2,[3]]]]", "flatten(1)", compact: true) == "[1,[2,[3]]]"
    end

    test "flatten already flat" do
      assert jq_ok("[1,2,3]", "flatten", compact: true) == "[1,2,3]"
    end
  end

  describe "group_by function" do
    test "group_by field" do
      json = ~S([{"k":"a","v":1},{"k":"b","v":2},{"k":"a","v":3}])
      result = jq_ok(json, "group_by(.k)", compact: true)
      # Should have 2 groups
      assert result =~ "\"k\":\"a\""
      assert result =~ "\"k\":\"b\""
    end
  end

  describe "string functions" do
    test "split" do
      assert jq_ok(~S("a,b,c"), "split(\",\")", compact: true) == ~S(["a","b","c"])
    end

    test "join" do
      json = ~S(["a","b","c"])
      assert jq_ok(json, "join(\"-\")", raw: true) == "a-b-c"
    end

    test "ascii_downcase" do
      assert jq_ok(~S("HELLO"), "ascii_downcase", raw: true) == "hello"
    end

    test "ascii_upcase" do
      assert jq_ok(~S("hello"), "ascii_upcase", raw: true) == "HELLO"
    end

    test "ltrimstr" do
      assert jq_ok(~S("hello world"), "ltrimstr(\"hello \")", raw: true) == "world"
    end

    test "ltrimstr no match" do
      assert jq_ok(~S("hello"), "ltrimstr(\"x\")", raw: true) == "hello"
    end

    test "rtrimstr" do
      assert jq_ok(~S("hello.txt"), "rtrimstr(\".txt\")", raw: true) == "hello"
    end

    test "startswith true" do
      assert jq_ok(~S("hello world"), "startswith(\"hello\")") == "true"
    end

    test "startswith false" do
      assert jq_ok(~S("hello world"), "startswith(\"world\")") == "false"
    end

    test "endswith true" do
      assert jq_ok(~S("hello.txt"), "endswith(\".txt\")") == "true"
    end

    test "endswith false" do
      assert jq_ok(~S("hello.txt"), "endswith(\".json\")") == "false"
    end
  end

  describe "type conversion" do
    test "tostring on number" do
      assert jq_ok("42", "tostring", raw: true) == "42"
    end

    test "tostring on string" do
      assert jq_ok(~S("hello"), "tostring", raw: true) == "hello"
    end

    test "tostring on null" do
      assert jq_ok("null", "tostring", raw: true) == "null"
    end

    test "tonumber from string" do
      assert jq_ok(~S("42"), "tonumber") == "42"
    end

    test "tonumber from float string" do
      result = jq_ok(~S("3.14"), "tonumber")
      assert String.to_float(result) == 3.14
    end

    test "tonumber from number" do
      assert jq_ok("42", "tonumber") == "42"
    end
  end

  describe "has function" do
    test "has existing key" do
      assert jq_ok(~S({"a":1}), "has(\"a\")") == "true"
    end

    test "has missing key" do
      assert jq_ok(~S({"a":1}), "has(\"b\")") == "false"
    end

    test "has on array" do
      assert jq_ok("[0,1,2]", "has(1)") == "true"
      assert jq_ok("[0,1,2]", "has(5)") == "false"
    end
  end

  describe "contains function" do
    test "array contains element" do
      assert jq_ok("[1,2,3]", "contains([2])") == "true"
    end

    test "array does not contain" do
      assert jq_ok("[1,2,3]", "contains([4])") == "false"
    end

    test "object contains subset" do
      json = ~S({"a":1,"b":2,"c":3})
      assert jq_ok(json, "contains({\"a\":1})") == "true"
    end

    test "string contains substring" do
      assert jq_ok(~S("hello world"), "contains(\"world\")") == "true"
    end
  end

  # ============================================================================
  # OBJECT AND ARRAY CONSTRUCTION
  # ============================================================================

  describe "object construction" do
    test "simple object" do
      result = jq_ok("5", "{value: .}", compact: true)
      assert result == ~S({"value":5})
    end

    test "object with multiple fields" do
      json = ~S({"a":1,"b":2})
      result = jq_ok(json, "{x: .a, y: .b}", compact: true)
      assert result =~ "\"x\":1"
      assert result =~ "\"y\":2"
    end

    test "object with string key" do
      result = jq_ok("5", "{\"key\": .}", compact: true)
      assert result == ~S({"key":5})
    end
  end

  describe "array construction" do
    test "simple array from values" do
      json = ~S({"a":1,"b":2})
      result = jq_ok(json, "[.a, .b]", compact: true)
      assert result == "[1,2]"
    end

    test "array from iterator" do
      json = ~S({"a":1,"b":2})
      result = jq_ok(json, "[.a, .b, .a + .b]", compact: true)
      assert result == "[1,2,3]"
    end

    test "empty array" do
      assert jq_ok("null", "[]", compact: true) == "[]"
    end
  end

  # ============================================================================
  # OPTIONAL OPERATOR
  # ============================================================================

  describe "optional operator (?)" do
    test "optional on existing field" do
      assert jq_ok(~S({"a":1}), ".a?") == "1"
    end

    test "optional on missing field" do
      assert jq_ok(~S({"a":1}), ".b?") == "null"
    end

    test "optional suppresses error on wrong type" do
      # Without ?, this would error
      result = jq_ok("[1,2,3]", ".foo?")
      assert result == "null"
    end

    test "optional with index" do
      assert jq_ok("[1,2,3]", ".[10]?") == "null"
    end
  end

  # ============================================================================
  # ERROR HANDLING
  # ============================================================================

  describe "error cases" do
    test "invalid JSON input" do
      bash = JustBash.new(files: %{"/data.json" => "not json"})
      {result, _} = JustBash.exec(bash, "jq '.' /data.json")
      assert result.exit_code == 1
      assert result.stderr =~ "parse error" or result.stderr =~ "Invalid JSON"
    end

    test "invalid filter syntax" do
      stderr = jq_err("{}", ".foo bar baz")
      assert stderr != ""
    end

    test "file not found" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "jq '.' /nonexistent.json")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  # ============================================================================
  # OPTIONS
  # ============================================================================

  describe "jq options" do
    test "-r raw output for strings" do
      assert jq_ok(~S("hello"), ".", raw: true) == "hello"
    end

    test "-r raw output does not affect non-strings" do
      assert jq_ok("42", ".", raw: true) == "42"
    end

    test "-c compact output" do
      json = ~S({"a":1,"b":2})
      result = jq_ok(json, ".", compact: true)
      refute result =~ "\n"
      assert result == ~S({"a":1,"b":2})
    end

    test "-n null input" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "jq -n '1 + 2'")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "3"
    end

    test "-s slurp mode" do
      json = "1\n2\n3"
      bash = JustBash.new(files: %{"/data.json" => json})
      {result, _} = JustBash.exec(bash, "jq -s 'add' /data.json")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "6"
    end
  end

  # ============================================================================
  # COMPLEX REAL-WORLD SCENARIOS
  # ============================================================================

  describe "real-world scenarios" do
    test "extract all emails from users" do
      json =
        ~S([{"name":"Alice","email":"alice@example.com"},{"name":"Bob","email":"bob@example.com"}])

      result = jq_ok(json, ".[].email", raw: true)
      assert result =~ "alice@example.com"
      assert result =~ "bob@example.com"
    end

    test "filter active users" do
      json =
        ~S([{"name":"Alice","active":true},{"name":"Bob","active":false},{"name":"Carol","active":true}])

      result = jq_ok(json, "[.[] | select(.active)] | length")
      assert String.trim(result) == "2"
    end

    test "transform data structure" do
      json = ~S({"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]})
      result = jq_ok(json, ".users | map({(.name): .id}) | add", compact: true)
      assert result =~ "\"Alice\":1"
      assert result =~ "\"Bob\":2"
    end

    test "count by field" do
      json = ~S([{"type":"a"},{"type":"b"},{"type":"a"},{"type":"a"},{"type":"b"}])

      result =
        jq_ok(json, "group_by(.type) | map({type: .[0].type, count: length})", compact: true)

      assert result =~ "\"type\":\"a\""
      assert result =~ "\"count\":3"
    end

    test "nested transformation" do
      json = ~S({"data":{"items":[{"value":10},{"value":20},{"value":30}]}})
      result = jq_ok(json, ".data.items | map(.value) | add")
      assert String.trim(result) == "60"
    end
  end
end
