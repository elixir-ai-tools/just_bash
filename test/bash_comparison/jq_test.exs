defmodule JustBash.BashComparison.JqTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  # Skip all tests if jq is not installed
  @jq_available System.find_executable("jq") != nil

  setup do
    if @jq_available do
      :ok
    else
      IO.puts("\n⚠️  jq not installed, skipping jq comparison tests")
      :ok
    end
  end

  describe "jq basic access comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq identity filter" do
      compare_bash("echo '{\"a\":1}' | jq -c '.'")
    end

    test "jq field access" do
      compare_bash("echo '{\"name\":\"alice\"}' | jq '.name'")
    end

    test "jq nested field access" do
      compare_bash("echo '{\"user\":{\"name\":\"bob\"}}' | jq '.user.name'")
    end

    test "jq array index" do
      compare_bash("echo '[10,20,30]' | jq '.[1]'")
    end

    test "jq array slice" do
      compare_bash("echo '[1,2,3,4,5]' | jq -c '.[1:4]'")
    end

    test "jq iterate array" do
      compare_bash("echo '[1,2,3]' | jq '.[]'")
    end

    test "jq access missing field returns null" do
      compare_bash("echo '{\"a\":1}' | jq '.missing'")
    end

    test "jq optional field access with ?" do
      compare_bash("echo 'null' | jq '.foo?'")
    end
  end

  describe "jq arithmetic comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq addition" do
      compare_bash("echo '5' | jq '. + 3'")
    end

    test "jq subtraction" do
      compare_bash("echo '10' | jq '. - 3'")
    end

    test "jq multiplication" do
      compare_bash("echo '5' | jq '. * 2'")
    end

    test "jq division" do
      compare_bash("echo '10' | jq '. / 2'")
    end

    test "jq modulo" do
      compare_bash("echo '17' | jq '. % 5'")
    end

    test "jq negative numbers" do
      compare_bash("echo '-5' | jq '. * 2'")
    end

    test "jq float arithmetic" do
      compare_bash("echo '3.5' | jq '. + 1.5'")
    end
  end

  describe "jq comparison operators" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq greater than" do
      compare_bash("echo '5' | jq '. > 3'")
    end

    test "jq less than" do
      compare_bash("echo '5' | jq '. < 10'")
    end

    test "jq greater than or equal" do
      compare_bash("echo '5' | jq '. >= 5'")
    end

    test "jq less than or equal" do
      compare_bash("echo '5' | jq '. <= 5'")
    end

    test "jq equality" do
      compare_bash("echo '5' | jq '. == 5'")
    end

    test "jq inequality" do
      compare_bash("echo '5' | jq '. != 3'")
    end
  end

  describe "jq logical operators comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq and operator" do
      compare_bash("echo 'true' | jq '. and false'")
    end

    test "jq or operator" do
      compare_bash("echo 'false' | jq '. or true'")
    end

    test "jq not operator" do
      compare_bash("echo 'true' | jq 'not'")
    end
  end

  describe "jq builtin functions comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq length of string" do
      compare_bash("echo '\"hello\"' | jq 'length'")
    end

    test "jq length of array" do
      compare_bash("echo '[1,2,3,4,5]' | jq 'length'")
    end

    test "jq length of object" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq 'length'")
    end

    test "jq keys" do
      compare_bash("echo '{\"b\":2,\"a\":1}' | jq -c 'keys'")
    end

    test "jq type of string" do
      compare_bash("echo '\"hello\"' | jq 'type'")
    end

    test "jq type of number" do
      compare_bash("echo '42' | jq 'type'")
    end

    test "jq type of array" do
      compare_bash("echo '[]' | jq 'type'")
    end

    test "jq type of object" do
      compare_bash("echo '{}' | jq 'type'")
    end

    test "jq type of boolean" do
      compare_bash("echo 'true' | jq 'type'")
    end

    test "jq type of null" do
      compare_bash("echo 'null' | jq 'type'")
    end
  end

  describe "jq array functions comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq first" do
      compare_bash("echo '[1,2,3]' | jq 'first'")
    end

    test "jq last" do
      compare_bash("echo '[1,2,3]' | jq 'last'")
    end

    test "jq reverse" do
      compare_bash("echo '[1,2,3]' | jq -c 'reverse'")
    end

    test "jq sort" do
      compare_bash("echo '[3,1,2]' | jq -c 'sort'")
    end

    test "jq unique" do
      compare_bash("echo '[1,2,1,3,2]' | jq -c 'unique'")
    end

    test "jq flatten" do
      compare_bash("echo '[[1,2],[3,[4,5]]]' | jq -c 'flatten'")
    end

    test "jq min" do
      compare_bash("echo '[5,2,8,1]' | jq 'min'")
    end

    test "jq max" do
      compare_bash("echo '[5,2,8,1]' | jq 'max'")
    end

    test "jq add numbers" do
      compare_bash("echo '[1,2,3,4]' | jq 'add'")
    end

    test "jq add strings" do
      compare_bash("echo '[\"a\",\"b\",\"c\"]' | jq 'add'")
    end

    test "jq nth element" do
      compare_bash("echo '[10,20,30,40]' | jq 'nth(2)'")
    end

    test "jq group_by" do
      compare_bash("echo '[{\"a\":1},{\"a\":2},{\"a\":1}]' | jq -c 'group_by(.a)'")
    end
  end

  describe "jq map and select comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq map with arithmetic" do
      compare_bash("echo '[1,2,3]' | jq -c 'map(. * 2)'")
    end

    test "jq map with field access" do
      compare_bash("echo '[{\"x\":1},{\"x\":2}]' | jq -c 'map(.x)'")
    end

    test "jq select greater than" do
      compare_bash("echo '[1,2,3,4,5]' | jq -c '[.[] | select(. > 2)]'")
    end

    test "jq select with equality" do
      compare_bash("echo '[{\"a\":1},{\"a\":2}]' | jq -c '[.[] | select(.a == 1)]'")
    end

    test "jq map_values" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq -c 'map_values(. + 10)'")
    end

    test "jq map_values with multiplication" do
      compare_bash("echo '{\"x\":2,\"y\":3}' | jq -c 'map_values(. * 2)'")
    end

    test "jq map_values with string transformation" do
      compare_bash("echo '{\"a\":\"hello\",\"b\":\"world\"}' | jq -c 'map_values(ascii_upcase)'")
    end
  end

  describe "jq string functions comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq ascii_downcase" do
      compare_bash("echo '\"HELLO\"' | jq 'ascii_downcase'")
    end

    test "jq ascii_upcase" do
      compare_bash("echo '\"hello\"' | jq 'ascii_upcase'")
    end

    test "jq split" do
      compare_bash("echo '\"a,b,c\"' | jq -c 'split(\",\")'")
    end

    test "jq join" do
      compare_bash("echo '[\"a\",\"b\",\"c\"]' | jq 'join(\"-\")'")
    end

    test "jq startswith true" do
      compare_bash("echo '\"hello world\"' | jq 'startswith(\"hello\")'")
    end

    test "jq startswith false" do
      compare_bash("echo '\"hello world\"' | jq 'startswith(\"world\")'")
    end

    test "jq endswith true" do
      compare_bash("echo '\"hello world\"' | jq 'endswith(\"world\")'")
    end

    test "jq endswith false" do
      compare_bash("echo '\"hello world\"' | jq 'endswith(\"hello\")'")
    end

    test "jq contains string" do
      compare_bash("echo '\"hello world\"' | jq 'contains(\"lo wo\")'")
    end

    test "jq ltrimstr" do
      compare_bash("echo '\"hello world\"' | jq 'ltrimstr(\"hello \")'")
    end

    test "jq rtrimstr" do
      compare_bash("echo '\"hello world\"' | jq 'rtrimstr(\" world\")'")
    end

    test "jq test regex match" do
      compare_bash("echo '\"hello123\"' | jq 'test(\"[0-9]+\")'")
    end

    test "jq test regex no match" do
      compare_bash("echo '\"hello\"' | jq 'test(\"[0-9]+\")'")
    end

    test "jq gsub replacement" do
      compare_bash("echo '\"hello world\"' | jq 'gsub(\"o\"; \"0\")'")
    end

    test "jq sub first replacement" do
      compare_bash("echo '\"hello world\"' | jq 'sub(\"o\"; \"0\")'")
    end
  end

  describe "jq object construction comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq object literal" do
      compare_bash("echo 'null' | jq -c '{a:1,b:2}'")
    end

    test "jq object from input values" do
      compare_bash("echo '{\"x\":1,\"y\":2}' | jq -c '{sum: (.x + .y)}'")
    end

    test "jq array construction" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq -c '[.a, .b]'")
    end

    test "jq object with dynamic key" do
      compare_bash("echo '{\"key\":\"name\",\"value\":\"alice\"}' | jq -c '{(.key): .value}'")
    end
  end

  describe "jq conditionals comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq if-then-else true branch" do
      compare_bash("echo '5' | jq 'if . > 3 then \"big\" else \"small\" end'")
    end

    test "jq if-then-else false branch" do
      compare_bash("echo '2' | jq 'if . > 3 then \"big\" else \"small\" end'")
    end

    test "jq alternative operator with null" do
      compare_bash("echo 'null' | jq '.x // \"default\"'")
    end

    test "jq alternative operator with value" do
      compare_bash("echo '{\"x\":5}' | jq '.x // \"default\"'")
    end

    test "jq empty check" do
      compare_bash("echo '[]' | jq 'if . == [] then \"empty\" else \"not empty\" end'")
    end
  end

  describe "jq pipeline and multiple outputs comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq multiple field access" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq '.a, .b'")
    end

    test "jq pipeline with filter" do
      compare_bash("echo '[1,2,3,4,5]' | jq '.[] | select(. > 2)'")
    end

    test "jq range function" do
      compare_bash("echo 'null' | jq -c '[range(5)]'")
    end

    test "jq range with start and end" do
      compare_bash("echo 'null' | jq -c '[range(2;5)]'")
    end
  end

  describe "jq format strings comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq @csv with numbers" do
      compare_bash("echo '[1,2,3]' | jq -r '@csv'")
    end

    test "jq @csv with strings" do
      compare_bash("echo '[\"a\",\"b\",\"c\"]' | jq -r '@csv'")
    end

    test "jq @tsv" do
      compare_bash("echo '[\"a\",\"b\",\"c\"]' | jq -r '@tsv'")
    end

    test "jq @json" do
      compare_bash("echo '{\"a\":1}' | jq -r '@json'")
    end

    test "jq @base64 encode" do
      compare_bash("echo '\"hello\"' | jq -r '@base64'")
    end

    test "jq @base64d decode" do
      compare_bash("echo '\"aGVsbG8=\"' | jq -r '@base64d'")
    end

    test "jq @uri encode" do
      compare_bash("echo '\"hello world\"' | jq -r '@uri'")
    end

    test "jq @html encode" do
      compare_bash("echo '\"<b>test</b>\"' | jq -r '@html'")
    end
  end

  describe "jq string interpolation comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq simple interpolation" do
      cmd = "echo '{\"name\":\"alice\"}' | jq -r '\"Hello, \\(.name)!\"'"
      compare_bash(cmd)
    end

    test "jq multiple interpolations" do
      cmd = "echo '{\"name\":\"alice\",\"age\":30}' | jq -r '\"\\(.name) is \\(.age) years old\"'"
      compare_bash(cmd)
    end

    test "jq interpolation with expression" do
      cmd = "echo '{\"a\":2,\"b\":3}' | jq -r '\"Sum: \\(.a + .b)\"'"
      compare_bash(cmd)
    end
  end

  describe "jq output options comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq raw output -r" do
      compare_bash("echo '\"hello\"' | jq -r '.'")
    end

    test "jq compact output -c" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq -c '.'")
    end

    test "jq sort keys -S" do
      # Use separate flags instead of combined -Sc (combined flags not supported)
      compare_bash("echo '{\"b\":2,\"a\":1}' | jq -S -c '.'")
    end
  end

  describe "jq reduce and recursive descent comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq reduce sum" do
      compare_bash("echo '[1,2,3,4,5]' | jq 'reduce .[] as $x (0; . + $x)'")
    end

    test "jq recursive descent .." do
      compare_bash("echo '{\"a\":{\"b\":1}}' | jq -c '[.. | numbers]'")
    end
  end

  describe "jq has and in operators comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq has existing key" do
      compare_bash("echo '{\"a\":1}' | jq 'has(\"a\")'")
    end

    test "jq has missing key" do
      compare_bash("echo '{\"a\":1}' | jq 'has(\"b\")'")
    end

    test "jq in operator for objects" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq '\"a\" | in({\"a\":1})'")
    end
  end

  describe "jq getpath and setpath comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq getpath" do
      compare_bash("echo '{\"a\":{\"b\":1}}' | jq 'getpath([\"a\",\"b\"])'")
    end

    test "jq setpath" do
      compare_bash("echo '{\"a\":1}' | jq -c 'setpath([\"b\"]; 2)'")
    end

    test "jq delpaths" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq -c 'delpaths([[\"a\"]])'")
    end
  end

  describe "jq to_entries and from_entries comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq to_entries" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq -c 'to_entries'")
    end

    test "jq from_entries" do
      compare_bash("echo '[{\"key\":\"a\",\"value\":1}]' | jq -c 'from_entries'")
    end

    test "jq with_entries with update assignment" do
      compare_bash("echo '{\"a\":1,\"b\":2}' | jq -c 'with_entries(.value += 10)'")
    end
  end

  describe "jq update assignment operators comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq += add assignment" do
      compare_bash("echo '{\"x\":5}' | jq -c '.x += 3'")
    end

    test "jq -= subtract assignment" do
      compare_bash("echo '{\"x\":10}' | jq -c '.x -= 3'")
    end

    test "jq *= multiply assignment" do
      compare_bash("echo '{\"x\":4}' | jq -c '.x *= 2'")
    end

    test "jq /= divide assignment" do
      compare_bash("echo '{\"x\":20}' | jq -c '.x /= 4'")
    end

    test "jq //= alternative assignment" do
      compare_bash("echo '{\"x\":null}' | jq -c '.x //= 5'")
    end

    test "jq //= alternative assignment with existing value" do
      compare_bash("echo '{\"x\":3}' | jq -c '.x //= 5'")
    end

    test "jq |= pipe assignment" do
      compare_bash("echo '{\"x\":5}' | jq -c '.x |= . + 1'")
    end

    test "jq nested update assignment" do
      compare_bash("echo '{\"a\":{\"b\":10}}' | jq -c '.a.b += 5'")
    end

    test "jq update assignment on array element" do
      compare_bash("echo '[1,2,3]' | jq -c '.[1] += 10'")
    end
  end

  describe "jq null handling comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq null input" do
      compare_bash("echo 'null' | jq '.'")
    end

    test "jq nulls in array" do
      compare_bash("echo '[1,null,2,null,3]' | jq -c '[.[] | select(. != null)]'")
    end

    test "jq empty filter" do
      compare_bash("echo '[1,2,3]' | jq -c '[.[] | if . == 2 then empty else . end]'")
    end
  end

  describe "jq any and all comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq any true" do
      compare_bash("echo '[false,true,false]' | jq 'any'")
    end

    test "jq any false" do
      compare_bash("echo '[false,false,false]' | jq 'any'")
    end

    test "jq all true" do
      compare_bash("echo '[true,true,true]' | jq 'all'")
    end

    test "jq all false" do
      compare_bash("echo '[true,false,true]' | jq 'all'")
    end
  end

  describe "jq edge cases comparison" do
    @describetag skip: if(!@jq_available, do: "jq not installed")

    test "jq empty array" do
      compare_bash("echo '[]' | jq -c '.'")
    end

    test "jq empty object" do
      compare_bash("echo '{}' | jq -c '.'")
    end

    test "jq special characters in string" do
      compare_bash("echo '{\"msg\":\"hello\\nworld\"}' | jq '.msg'")
    end

    test "jq unicode" do
      compare_bash("echo '{\"emoji\":\"🎉\"}' | jq '.emoji'")
    end

    test "jq large number" do
      compare_bash("echo '12345678901234567890' | jq '.'")
    end

    test "jq nested arrays" do
      compare_bash("echo '[[1,2],[3,4]]' | jq -c '.[]'")
    end
  end
end
