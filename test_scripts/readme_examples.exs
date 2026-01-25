# Test all README examples
# Usage: mix run test_scripts/readme_examples.exs

defmodule ReadmeExamples do
  def run do
    IO.puts("Testing README Examples")
    IO.puts(String.duplicate("=", 70))

    results = [
      # Basic Usage section
      test(
        "Basic echo",
        "echo 'Hello World'",
        "Hello World\n"
      ),
      test(
        "Pipeline sort",
        "printf 'cherry\\napple\\nbanana' | sort | head -2",
        "apple\nbanana\n"
      ),
      test(
        "Variables and arithmetic",
        "x=42; echo $((x * 2))",
        "84\n"
      ),
      test(
        "For loop",
        "for i in 1 2 3; do echo $i; done",
        "1\n2\n3\n"
      ),

      # Variable expansions
      test(
        "Simple expansion",
        "VAR=hello; echo $VAR",
        "hello\n"
      ),
      test(
        "Braced expansion",
        "VAR=hello; echo ${VAR}",
        "hello\n"
      ),
      test(
        "Default if unset",
        "echo ${UNSET:-default}",
        "default\n"
      ),
      test(
        "Assign default",
        "echo ${NEW:=assigned}; echo $NEW",
        "assigned\nassigned\n"
      ),
      test(
        "Alternate if set",
        "VAR=x; echo ${VAR:+alternate}",
        "alternate\n"
      ),
      test(
        "String length",
        "VAR=hello; echo ${#VAR}",
        "5\n"
      ),
      test(
        "Substring",
        "VAR=hello; echo ${VAR:1:3}",
        "ell\n"
      ),
      test(
        "Remove prefix #",
        "VAR=/path/to/file; echo ${VAR#*/}",
        "path/to/file\n"
      ),
      test(
        "Remove prefix ##",
        "VAR=/path/to/file; echo ${VAR##*/}",
        "file\n"
      ),
      test(
        "Remove suffix %",
        "VAR=/path/to/file; echo ${VAR%/*}",
        "/path/to\n"
      ),
      test(
        "Remove suffix %%",
        "VAR=/path/to/file.txt; echo ${VAR%%.*}",
        "/path/to/file\n"
      ),
      test(
        "Replace first",
        "VAR=\"hello world\"; echo ${VAR/world/there}",
        "hello there\n"
      ),
      test(
        "Replace all",
        "VAR=\"hello hello\"; echo ${VAR//hello/hi}",
        "hi hi\n"
      ),

      # Brace expansion
      test(
        "Brace list",
        "echo {a,b,c}",
        "a b c\n"
      ),
      test(
        "Brace range",
        "echo {1..5}",
        "1 2 3 4 5\n"
      ),
      test(
        "Brace alpha",
        "echo {a..e}",
        "a b c d e\n"
      ),
      test(
        "Brace with text",
        "echo file{1,2,3}.txt",
        "file1.txt file2.txt file3.txt\n"
      ),

      # Arithmetic
      test(
        "Arithmetic expansion",
        "x=5; y=3; echo $((x + y))",
        "8\n"
      ),
      test(
        "Exponentiation",
        "x=3; echo $((x ** 2))",
        "9\n"
      ),
      test(
        "Ternary",
        "x=5; y=3; echo $((x > y ? x : y))",
        "5\n"
      ),
      test(
        "Hex",
        "echo $((0xFF))",
        "255\n"
      ),

      # Control flow
      test(
        "If statement",
        "x=5; if [ $x -gt 3 ]; then echo big; else echo small; fi",
        "big\n"
      ),
      test(
        "For loop list",
        "for item in a b c; do echo $item; done",
        "a\nb\nc\n"
      ),
      test(
        "While loop",
        "x=1; while [ $x -le 3 ]; do echo $x; x=$((x+1)); done",
        "1\n2\n3\n"
      ),
      test(
        "Case statement",
        "var=apple; case $var in apple) echo fruit;; *) echo other;; esac",
        "fruit\n"
      ),
      test(
        "Function",
        "greet() { echo \"Hello, $1!\"; }; greet World",
        "Hello, World!\n"
      ),

      # Pipes & Operators
      test(
        "Pipeline",
        "printf '3\\n1\\n2' | sort",
        "1\n2\n3\n"
      ),
      test(
        "AND operator",
        "true && echo yes",
        "yes\n"
      ),
      test(
        "OR operator",
        "false || echo fallback",
        "fallback\n"
      ),
      test(
        "Negate",
        "! false && echo negated",
        "negated\n"
      ),

      # Redirections
      test(
        "Stdout to file",
        "echo hello > /tmp/test.txt; cat /tmp/test.txt",
        "hello\n"
      ),
      test(
        "Append",
        "echo a > /tmp/t.txt; echo b >> /tmp/t.txt; cat /tmp/t.txt",
        "a\nb\n"
      ),
      test(
        "Stderr redirect",
        "cat /nonexistent 2>/dev/null; echo $?",
        "1\n"
      ),
      test(
        "Here-document",
        "cat <<EOF\nhello\nworld\nEOF",
        "hello\nworld\n"
      ),

      # Subshell and group
      test(
        "Subshell",
        "x=1; (x=2); echo $x",
        "1\n"
      ),
      test(
        "Group",
        "{ echo a; echo b; }",
        "a\nb\n"
      ),

      # jq examples
      test(
        "jq basic access",
        "echo '{\"name\":\"alice\"}' | jq '.name'",
        "\"alice\"\n"
      ),
      test(
        "jq array index",
        "echo '[1,2,3]' | jq '.[0]'",
        "1\n"
      ),
      test(
        "jq iterate",
        "echo '[1,2,3]' | jq '.[]'",
        "1\n2\n3\n"
      ),
      test(
        "jq select",
        "echo '[{\"a\":1},{\"a\":2}]' | jq -c '.[] | select(.a > 1)'",
        "{\"a\":2}\n"
      ),
      test(
        "jq map",
        "echo '[1,2,3]' | jq -c 'map(. * 2)'",
        "[2,4,6]\n"
      ),
      test(
        "jq keys",
        "echo '{\"a\":1,\"b\":2}' | jq -c 'keys'",
        "[\"a\",\"b\"]\n"
      ),
      test(
        "jq sort",
        "echo '[3,1,2]' | jq -c 'sort'",
        "[1,2,3]\n"
      ),
      test(
        "jq construct object",
        "echo '{\"first\":\"a\",\"last\":\"b\"}' | jq -c '{name: .first}'",
        "{\"name\":\"a\"}\n"
      ),
      test(
        "jq ascii_upcase",
        "echo '\"hello\"' | jq 'ascii_upcase'",
        "\"HELLO\"\n"
      ),
      test(
        "jq split",
        "echo '\"hello world\"' | jq -c 'split(\" \")'",
        "[\"hello\",\"world\"]\n"
      ),
      test(
        "jq conditional",
        "echo '5' | jq 'if . > 3 then \"big\" else \"small\" end'",
        "\"big\"\n"
      ),

      # Text commands
      test(
        "grep basic",
        "printf 'apple\\nbanana\\napricot' | grep '^a'",
        "apple\napricot\n"
      ),
      test(
        "grep -i",
        "printf 'Apple\\napple' | grep -i 'APPLE'",
        "Apple\napple\n"
      ),
      test(
        "grep -v",
        "printf 'yes\\nno' | grep -v 'no'",
        "yes\n"
      ),
      test(
        "grep -c",
        "echo 'hello' | grep -c 'l'",
        "1\n"
      ),
      test(
        "sed substitute",
        "echo 'hello world' | sed 's/world/there/'",
        "hello there\n"
      ),
      test(
        "sed global",
        "echo 'aaa' | sed 's/a/b/g'",
        "bbb\n"
      ),
      test(
        "cut -d -f",
        "echo 'a:b:c' | cut -d: -f2",
        "b\n"
      ),
      test(
        "sort",
        "printf 'c\\na\\nb' | sort",
        "a\nb\nc\n"
      ),
      test(
        "sort -n",
        "printf '10\\n2\\n1' | sort -n",
        "1\n2\n10\n"
      ),
      test(
        "sort -r",
        "printf 'a\\nb\\nc' | sort -r",
        "c\nb\na\n"
      ),
      test(
        "uniq",
        "printf 'a\\na\\nb' | uniq",
        "a\nb\n"
      ),
      test(
        "uniq -c",
        "printf 'a\\na\\nb' | uniq -c",
        "      2 a\n      1 b\n"
      ),
      test(
        "head",
        "printf '1\\n2\\n3\\n4\\n5' | head -2",
        "1\n2\n"
      ),
      test(
        "tail",
        "printf '1\\n2\\n3\\n4\\n5' | tail -2",
        "4\n5\n"
      ),
      test(
        "wc -l",
        "printf 'a\\nb\\nc\\n' | wc -l",
        "       3\n"
      ),
      test(
        "wc -w",
        "echo 'one two three' | wc -w",
        "       3\n"
      ),
      test(
        "tr lowercase to uppercase",
        "echo 'hello' | tr 'a-z' 'A-Z'",
        "HELLO\n"
      ),
      test(
        "tr -d delete",
        "echo 'hello' | tr -d 'l'",
        "heo\n"
      ),
      test(
        "basename",
        "basename /path/to/file.txt",
        "file.txt\n"
      ),
      test(
        "dirname",
        "dirname /path/to/file.txt",
        "/path/to\n"
      ),
      test(
        "seq",
        "seq 3",
        "1\n2\n3\n"
      ),
      test(
        "rev",
        "echo 'hello' | rev",
        "olleh\n"
      ),
      test(
        "tac",
        "printf 'a\\nb\\nc' | tac",
        "c\nb\na\n"
      ),

      # base64
      test(
        "base64 encode",
        "echo -n 'hello' | base64",
        "aGVsbG8=\n"
      ),
      test(
        "base64 decode",
        "echo 'aGVsbG8=' | base64 -d",
        "hello"
      ),

      # awk examples  
      test(
        "awk print field",
        "echo 'a b c' | awk '{print $2}'",
        "b\n"
      ),
      test(
        "awk -F delimiter",
        "echo 'a:b:c' | awk -F: '{print $2}'",
        "b\n"
      ),
      test(
        "awk NR line number",
        "printf 'a\\nb\\nc' | awk '{print NR, $0}'",
        "1 a\n2 b\n3 c\n"
      ),
      test(
        "awk NF field count",
        "echo 'one two three' | awk '{print NF}'",
        "3\n"
      ),

      # Extended test command
      test(
        "[[ regex match ]]",
        "x=hello123; [[ $x =~ ^[a-z]+[0-9]+$ ]] && echo match",
        "match\n"
      ),

      # More shell features
      test(
        "Command substitution nested",
        "echo $(echo $(echo nested))",
        "nested\n"
      ),
      test(
        "Arithmetic increment",
        "x=5; echo $((x++)); echo $x",
        "5\n6\n"
      ),
      test(
        "Binary literal",
        "echo $((2#1010))",
        "10\n"
      )
    ]

    print_summary(results)
  end

  defp test(name, script, expected) do
    bash = JustBash.new()
    {result, _} = JustBash.exec(bash, script)

    passed = result.stdout == expected

    status = if passed, do: "PASS", else: "FAIL"
    IO.puts("#{status}: #{name}")

    unless passed do
      IO.puts("  Script:   #{inspect(script)}")
      IO.puts("  Expected: #{inspect(expected)}")
      IO.puts("  Got:      #{inspect(result.stdout)}")

      if result.stderr != "" do
        IO.puts("  Stderr:   #{inspect(result.stderr)}")
      end
    end

    %{name: name, passed: passed}
  end

  defp print_summary(results) do
    IO.puts(String.duplicate("=", 70))

    total = length(results)
    passed = Enum.count(results, & &1.passed)
    failed = total - passed

    IO.puts("SUMMARY: #{passed}/#{total} passed, #{failed} failed")

    if failed > 0 do
      IO.puts("\nFailed tests:")

      results
      |> Enum.filter(&(not &1.passed))
      |> Enum.each(fn r -> IO.puts("  - #{r.name}") end)

      System.halt(1)
    else
      IO.puts("\nAll README examples work correctly!")
    end
  end
end

ReadmeExamples.run()
