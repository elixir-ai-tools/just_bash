defmodule JustBash.Commands.AwkTest do
  @moduledoc """
  Comprehensive tests for the awk command.

  Based on Vercel's just-bash test suite with additional tests
  for edge cases and specific features.
  """
  use ExUnit.Case, async: true

  describe "basic field access" do
    test "print entire line with $0" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\nfoo bar\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $0}' /data.txt")
      assert result.stdout == "hello world\nfoo bar\n"
      assert result.exit_code == 0
    end

    test "print first field with $1" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\nfoo bar\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1}' /data.txt")
      assert result.stdout == "hello\nfoo\n"
      assert result.exit_code == 0
    end

    test "print multiple fields" do
      bash = JustBash.new(files: %{"/data.txt" => "a b c\n1 2 3\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1, $3}' /data.txt")
      assert result.stdout == "a c\n1 3\n"
      assert result.exit_code == 0
    end

    test "handle missing fields gracefully" do
      bash = JustBash.new(files: %{"/data.txt" => "one\ntwo three\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $2}' /data.txt")
      assert result.stdout == "\nthree\n"
      assert result.exit_code == 0
    end

    test "access field beyond NF returns empty" do
      bash = JustBash.new(files: %{"/data.txt" => "a b c\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $10}' /data.txt")
      assert result.stdout == "\n"
      assert result.exit_code == 0
    end

    test "print last field with $NF" do
      # $NF (dynamic field via NF variable) not yet implemented
      bash = JustBash.new(files: %{"/data.txt" => "a b c d\n1 2 3\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $NF}' /data.txt")
      assert result.stdout == "d\n3\n"
      assert result.exit_code == 0
    end
  end

  describe "field separator -F" do
    test "use custom field separator" do
      bash = JustBash.new(files: %{"/data.csv" => "a,b,c\n1,2,3\n"})
      {result, _} = JustBash.exec(bash, "awk -F',' '{print $2}' /data.csv")
      assert result.stdout == "b\n2\n"
      assert result.exit_code == 0
    end

    test "handle -F without space" do
      bash = JustBash.new(files: %{"/data.csv" => "a:b:c\n"})
      {result, _} = JustBash.exec(bash, "awk -F: '{print $2}' /data.csv")
      assert result.stdout == "b\n"
      assert result.exit_code == 0
    end

    test "tab as field separator" do
      bash = JustBash.new(files: %{"/data.tsv" => "a\tb\tc\n"})
      {result, _} = JustBash.exec(bash, "awk -F'\t' '{print $2}' /data.tsv")
      assert result.stdout == "b\n"
      assert result.exit_code == 0
    end

    test "default whitespace splitting collapses multiple spaces" do
      bash = JustBash.new(files: %{"/data.txt" => "a   b    c\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $2}' /data.txt")
      assert result.stdout == "b\n"
      assert result.exit_code == 0
    end

    test "single-char separator does not collapse" do
      bash = JustBash.new(files: %{"/data.txt" => "a,,b,c\n"})
      {result, _} = JustBash.exec(bash, "awk -F',' '{print $2, $3}' /data.txt")
      assert result.stdout == " b\n"
      assert result.exit_code == 0
    end
  end

  describe "variable assignment -v" do
    test "use -v assigned variable" do
      # String concatenation in print args not fully working
      bash = JustBash.new(files: %{"/data.txt" => "test\n"})
      {result, _} = JustBash.exec(bash, ~s|awk -v name=World '{print "Hello " name}' /data.txt|)
      assert result.stdout == "Hello World\n"
      assert result.exit_code == 0
    end

    test "-v with numeric value" do
      bash = JustBash.new(files: %{"/data.txt" => "10\n"})
      {result, _} = JustBash.exec(bash, "awk -v x=5 '{print $1 + x}' /data.txt")
      assert result.stdout == "15\n"
      assert result.exit_code == 0
    end

    test "multiple -v assignments" do
      bash = JustBash.new(files: %{"/data.txt" => "test\n"})
      {result, _} = JustBash.exec(bash, ~s|awk -v a=1 -v b=2 'BEGIN{print a + b}'|)
      assert result.stdout == "3\n"
      assert result.exit_code == 0
    end
  end

  describe "built-in variables" do
    test "track NR (record number)" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\nc\n"})
      {result, _} = JustBash.exec(bash, "awk '{print NR, $0}' /data.txt")
      assert result.stdout == "1 a\n2 b\n3 c\n"
      assert result.exit_code == 0
    end

    test "track NF (number of fields)" do
      bash = JustBash.new(files: %{"/data.txt" => "one\ntwo three\na b c d\n"})
      {result, _} = JustBash.exec(bash, "awk '{print NF}' /data.txt")
      assert result.stdout == "1\n2\n4\n"
      assert result.exit_code == 0
    end

    test "NF=0 for empty line" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '' | awk '{ print NF }'")
      assert result.stdout == "0\n"
      assert result.exit_code == 0
    end

    test "NF=0 for whitespace-only line (default FS)" do
      bash = JustBash.new(files: %{"/data.txt" => "   \n"})
      {result, _} = JustBash.exec(bash, "awk '{ print NF }' /data.txt")
      assert result.stdout == "0\n"
      assert result.exit_code == 0
    end

    test "FS variable" do
      bash = JustBash.new(files: %{"/data.txt" => "a,b,c\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{FS=","}{print $2}' /data.txt|)
      assert result.stdout == "b\n"
      assert result.exit_code == 0
    end

    test "OFS variable" do
      bash = JustBash.new(files: %{"/data.txt" => "a b c\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{OFS="-"}{print $1, $2, $3}' /data.txt|)
      assert result.stdout == "a-b-c\n"
      assert result.exit_code == 0
    end

    test "ORS variable" do
      # ORS assignment in BEGIN block not working correctly
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{ORS=";"}{print $0}' /data.txt|)
      assert result.stdout == "a;b;"
      assert result.exit_code == 0
    end
  end

  describe "BEGIN and END blocks" do
    test "execute BEGIN block before processing" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{print "start"}{print $0}' /data.txt|)
      assert result.stdout == "start\na\nb\n"
      assert result.exit_code == 0
    end

    test "execute END block after processing" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{print $0}END{print "done"}' /data.txt|)
      assert result.stdout == "a\nb\ndone\n"
      assert result.exit_code == 0
    end

    test "execute BEGIN even with no input" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{print "hello"}' /empty.txt|)
      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end

    test "BEGIN and END with main rule" do
      bash = JustBash.new(files: %{"/data.txt" => "1\n2\n3\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{sum=0}{sum+=$1}END{print sum}' /data.txt|)
      assert result.stdout == "6\n"
      assert result.exit_code == 0
    end

    test "multiple BEGIN blocks" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{print "a"}BEGIN{print "b"}'|)
      assert result.stdout == "a\nb\n"
      assert result.exit_code == 0
    end

    test "multiple END blocks" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'END{print "a"}END{print "b"}' /data.txt|)
      assert result.stdout == "a\nb\n"
      assert result.exit_code == 0
    end
  end

  describe "pattern matching" do
    test "filter lines with regex pattern" do
      bash = JustBash.new(files: %{"/data.txt" => "apple\nbanana\napricot\ncherry\n"})
      {result, _} = JustBash.exec(bash, "awk '/^a/{print}' /data.txt")
      assert result.stdout == "apple\napricot\n"
      assert result.exit_code == 0
    end

    test "regex pattern without explicit action" do
      bash = JustBash.new(files: %{"/data.txt" => "foo\nbar\nbaz\n"})
      {result, _} = JustBash.exec(bash, "awk '/ba/' /data.txt")
      assert result.stdout == "bar\nbaz\n"
      assert result.exit_code == 0
    end

    test "match with NR condition ==" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "awk 'NR==2{print}' /data.txt")
      assert result.stdout == "line2\n"
      assert result.exit_code == 0
    end

    test "match with NR > condition" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "awk 'NR>1{print}' /data.txt")
      assert result.stdout == "line2\nline3\n"
      assert result.exit_code == 0
    end

    test "match with NR < condition" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "awk 'NR<3{print}' /data.txt")
      assert result.stdout == "line1\nline2\n"
      assert result.exit_code == 0
    end

    test "match with NR >= condition" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "awk 'NR>=2{print}' /data.txt")
      assert result.stdout == "line2\nline3\n"
      assert result.exit_code == 0
    end

    test "match with NR <= condition" do
      bash = JustBash.new(files: %{"/data.txt" => "line1\nline2\nline3\n"})
      {result, _} = JustBash.exec(bash, "awk 'NR<=2{print}' /data.txt")
      assert result.stdout == "line1\nline2\n"
      assert result.exit_code == 0
    end

    test "field equality condition" do
      bash = JustBash.new(files: %{"/data.txt" => "yes hello\nno goodbye\nyes world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '$1=="yes"{print $2}' /data.txt|)
      assert result.stdout == "hello\nworld\n"
      assert result.exit_code == 0
    end

    test "field regex match condition" do
      bash = JustBash.new(files: %{"/data.txt" => "abc 1\nxyz 2\nabc 3\n"})
      {result, _} = JustBash.exec(bash, "awk '$1 ~ /^a/{print $2}' /data.txt")
      assert result.stdout == "1\n3\n"
      assert result.exit_code == 0
    end
  end

  describe "printf" do
    test "format with printf %s" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{printf "%s!\\n", $1}' /data.txt|)
      assert result.stdout == "hello!\n"
      assert result.exit_code == 0
    end

    test "format with printf %d" do
      bash = JustBash.new(files: %{"/data.txt" => "42\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{printf "num: %d\\n", $1}' /data.txt|)
      assert result.stdout == "num: 42\n"
      assert result.exit_code == 0
    end

    test "printf with width specifier" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{printf "%5d\\n", 42}'|)
      assert result.stdout == "   42\n"
      assert result.exit_code == 0
    end

    test "printf with left justify" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{printf "%-5d\|\\n", 42}'|)
      assert result.stdout == "42   \|\n"
      assert result.exit_code == 0
    end

    test "printf with float precision" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{printf "%.2f\\n", 3.14159}'|)
      assert result.stdout == "3.14\n"
      assert result.exit_code == 0
    end

    test "printf multiple arguments" do
      # Printf with text between format specifiers fails
      bash = JustBash.new(files: %{"/data.txt" => "John 25\n"})

      {result, _} =
        JustBash.exec(bash, ~s|awk '{printf "%s is %d years old\\n", $1, $2}' /data.txt|)

      assert result.stdout == "John is 25 years old\n"
      assert result.exit_code == 0
    end
  end

  describe "stdin input" do
    test "read from piped stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'a b c' | awk '{print $2}'")
      assert result.stdout == "b\n"
      assert result.exit_code == 0
    end

    test "multiline stdin" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "printf 'a\\nb\\nc\\n' | awk '{print NR, $0}'")
      assert result.stdout == "1 a\n2 b\n3 c\n"
      assert result.exit_code == 0
    end
  end

  describe "arithmetic" do
    test "perform addition" do
      bash = JustBash.new(files: %{"/data.txt" => "10 20\n5 15\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1 + $2}' /data.txt")
      assert result.stdout == "30\n20\n"
      assert result.exit_code == 0
    end

    test "perform subtraction" do
      bash = JustBash.new(files: %{"/data.txt" => "10 3\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1 - $2}' /data.txt")
      assert result.stdout == "7\n"
      assert result.exit_code == 0
    end

    test "perform multiplication" do
      bash = JustBash.new(files: %{"/data.txt" => "6 7\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1 * $2}' /data.txt")
      assert result.stdout == "42\n"
      assert result.exit_code == 0
    end

    test "perform division" do
      bash = JustBash.new(files: %{"/data.txt" => "20 4\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1 / $2}' /data.txt")
      assert result.stdout == "5\n"
      assert result.exit_code == 0
    end

    test "division by zero returns 0" do
      bash = JustBash.new(files: %{"/data.txt" => "10 0\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1 / $2}' /data.txt")
      # Our implementation returns 0 for division by zero
      assert result.stdout == "0\n"
      assert result.exit_code == 0
    end

    test "arithmetic with string coercion" do
      bash = JustBash.new(files: %{"/data.txt" => "10abc 5\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1 + $2}' /data.txt")
      assert result.stdout == "15\n"
      assert result.exit_code == 0
    end
  end

  describe "compound assignment operators" do
    test "handle += operator" do
      bash = JustBash.new(files: %{"/data.txt" => "10\n20\n30\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{sum=0}{sum+=$1}END{print sum}' /data.txt")
      assert result.stdout == "60\n"
      assert result.exit_code == 0
    end

    test "accumulate with += across multiple lines (CSV)" do
      bash = JustBash.new(files: %{"/sales.csv" => "product,100\nservice,250\nsubscription,50\n"})
      {result, _} = JustBash.exec(bash, "awk -F, '{total+=$2}END{print total}' /sales.csv")
      assert result.stdout == "400\n"
      assert result.exit_code == 0
    end
  end

  describe "increment/decrement operators" do
    test "handle var++ postfix increment" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\nc\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{n=0}{n++}END{print n}' /data.txt")
      assert result.stdout == "3\n"
      assert result.exit_code == 0
    end

    test "count lines with increment" do
      bash = JustBash.new(files: %{"/data.txt" => "x\ny\nz\n"})
      {result, _} = JustBash.exec(bash, "awk '{count++}END{print count}' /data.txt")
      assert result.stdout == "3\n"
      assert result.exit_code == 0
    end
  end

  describe "string functions" do
    test "length() with no argument uses $0" do
      bash = JustBash.new(files: %{"/data.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "awk '{print length()}' /data.txt")
      assert result.stdout == "5\n"
      assert result.exit_code == 0
    end

    test "length() with argument" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, "awk '{print length($1)}' /data.txt")
      assert result.stdout == "5\n"
      assert result.exit_code == 0
    end

    test "substr() with start" do
      bash = JustBash.new(files: %{"/data.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{print substr($0, 3)}' /data.txt|)
      assert result.stdout == "llo\n"
      assert result.exit_code == 0
    end

    test "substr() with start and length" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{print substr($0, 1, 5)}' /data.txt|)
      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end

    test "tolower()" do
      bash = JustBash.new(files: %{"/data.txt" => "HELLO World\n"})
      {result, _} = JustBash.exec(bash, "awk '{print tolower($0)}' /data.txt")
      assert result.stdout == "hello world\n"
      assert result.exit_code == 0
    end

    test "toupper()" do
      bash = JustBash.new(files: %{"/data.txt" => "hello World\n"})
      {result, _} = JustBash.exec(bash, "awk '{print toupper($0)}' /data.txt")
      assert result.stdout == "HELLO WORLD\n"
      assert result.exit_code == 0
    end

    test "index() finds position" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{print index($0, "wor")}' /data.txt|)
      assert result.stdout == "7\n"
      assert result.exit_code == 0
    end

    test "index() returns 0 when not found" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{print index($0, "xyz")}' /data.txt|)
      assert result.stdout == "0\n"
      assert result.exit_code == 0
    end

    test "sprintf() formats string" do
      # sprintf zero-padding not working
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{s=sprintf("%05d", 42); print s}'|)
      assert result.stdout == "00042\n"
      assert result.exit_code == 0
    end
  end

  describe "gsub and sub" do
    test "gsub replaces all occurrences" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{gsub(/o/, "0"); print}' /data.txt|)
      assert result.stdout == "hell0 w0rld\n"
      assert result.exit_code == 0
    end

    test "sub replaces first occurrence only" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{sub(/o/, "0"); print}' /data.txt|)
      assert result.stdout == "hell0 world\n"
      assert result.exit_code == 0
    end

    test "gsub on specific field" do
      bash = JustBash.new(files: %{"/data.txt" => "foo bar\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{gsub(/o/, "0", $1); print $1}' /data.txt|)
      assert result.stdout == "f00\n"
      assert result.exit_code == 0
    end
  end

  describe "if-else statements" do
    test "simple if condition" do
      bash = JustBash.new(files: %{"/data.txt" => "5\n15\n25\n"})

      {result, _} =
        JustBash.exec(bash, ~s|awk '{if ($1 > 10) print "big"; else print "small"}' /data.txt|)

      assert result.stdout == "small\nbig\nbig\n"
      assert result.exit_code == 0
    end

    test "if with == comparison" do
      bash = JustBash.new(files: %{"/data.txt" => "1\n2\n1\n"})

      {result, _} =
        JustBash.exec(bash, ~s|awk '{if ($1 == 1) print "one"; else print "other"}' /data.txt|)

      assert result.stdout == "one\nother\none\n"
      assert result.exit_code == 0
    end

    test "if with string comparison" do
      bash = JustBash.new(files: %{"/data.txt" => "yes\nno\nyes\n"})

      {result, _} =
        JustBash.exec(bash, ~s|awk '{if ($1 == "yes") print "Y"; else print "N"}' /data.txt|)

      assert result.stdout == "Y\nN\nY\n"
      assert result.exit_code == 0
    end
  end

  describe "ternary operator" do
    test "ternary in print expression" do
      bash = JustBash.new(files: %{"/data.txt" => "5\n15\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{print ($1 > 10) ? "big" : "small"}' /data.txt|)
      assert result.stdout == "small\nbig\n"
      assert result.exit_code == 0
    end
  end

  describe "error handling" do
    test "error on missing program" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "awk")
      assert result.exit_code == 1
      assert result.stderr =~ "missing program"
    end

    test "error on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "awk '{print}' /nonexistent.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "show help with --help" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "awk --help")
      assert result.stdout =~ "awk"
      assert result.stdout =~ "pattern scanning"
      assert result.exit_code == 0
    end
  end

  describe "multiple files" do
    test "process multiple files in order" do
      bash = JustBash.new(files: %{"/a.txt" => "a\n", "/b.txt" => "b\n"})
      {result, _} = JustBash.exec(bash, "awk '{print NR, $0}' /a.txt /b.txt")
      assert result.stdout == "1 a\n2 b\n"
      assert result.exit_code == 0
    end
  end

  describe "real-world patterns" do
    test "sum column values" do
      bash = JustBash.new(files: %{"/data.txt" => "item1 10\nitem2 20\nitem3 30\n"})
      {result, _} = JustBash.exec(bash, "awk '{sum+=$2}END{print sum}' /data.txt")
      assert result.stdout == "60\n"
      assert result.exit_code == 0
    end

    test "calculate average" do
      bash = JustBash.new(files: %{"/data.txt" => "10\n20\n30\n"})
      {result, _} = JustBash.exec(bash, "awk '{sum+=$1; count++}END{print sum/count}' /data.txt")
      assert result.stdout == "20\n"
      assert result.exit_code == 0
    end

    test "find max value" do
      # Field > variable comparison in pattern not working
      bash = JustBash.new(files: %{"/data.txt" => "10\n25\n15\n30\n5\n"})

      {result, _} =
        JustBash.exec(bash, "awk 'BEGIN{max=0}$1>max{max=$1}END{print max}' /data.txt")

      assert result.stdout == "30\n"
      assert result.exit_code == 0
    end

    test "find min value" do
      # Field < variable comparison in pattern not working
      bash = JustBash.new(files: %{"/data.txt" => "10\n25\n15\n30\n5\n"})

      {result, _} =
        JustBash.exec(bash, "awk 'BEGIN{min=9999}$1<min{min=$1}END{print min}' /data.txt")

      assert result.stdout == "5\n"
      assert result.exit_code == 0
    end

    test "print specific columns from CSV" do
      csv = "name,age,city\nAlice,30,NYC\nBob,25,LA\n"
      bash = JustBash.new(files: %{"/data.csv" => csv})
      {result, _} = JustBash.exec(bash, "awk -F, 'NR>1{print $1, $3}' /data.csv")
      assert result.stdout == "Alice NYC\nBob LA\n"
      assert result.exit_code == 0
    end

    test "filter and transform data" do
      # Field comparison patterns not working correctly
      bash =
        JustBash.new(
          files: %{"/prices.csv" => "apple,1.50\nbanana,0.75\norange,2.00\ngrape,3.50\n"}
        )

      {result, _} = JustBash.exec(bash, "awk -F, '$2>=2{print $1}' /prices.csv")
      assert result.stdout == "orange\ngrape\n"
      assert result.exit_code == 0
    end

    test "count lines matching pattern" do
      bash =
        JustBash.new(
          files: %{"/log.txt" => "INFO: start\nERROR: fail\nINFO: done\nERROR: crash\n"}
        )

      {result, _} = JustBash.exec(bash, "awk '/ERROR/{count++}END{print count}' /log.txt")
      assert result.stdout == "2\n"
      assert result.exit_code == 0
    end

    test "transform field values" do
      # Function calls in print with comma separator not working
      bash = JustBash.new(files: %{"/names.txt" => "john doe\njane smith\n"})
      {result, _} = JustBash.exec(bash, "awk '{print toupper($1), toupper($2)}' /names.txt")
      assert result.stdout == "JOHN DOE\nJANE SMITH\n"
      assert result.exit_code == 0
    end

    test "formatted output with printf" do
      # Printf with literal $ between format specifiers fails
      bash = JustBash.new(files: %{"/data.txt" => "Alice 1000\nBob 2500\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{printf "%-10s $%d\\n", $1, $2}' /data.txt|)
      assert result.stdout == "Alice      $1000\nBob        $2500\n"
      assert result.exit_code == 0
    end
  end

  describe "edge cases" do
    test "empty input file" do
      bash = JustBash.new(files: %{"/empty.txt" => ""})
      {result, _} = JustBash.exec(bash, "awk '{print $1}' /empty.txt")
      assert result.stdout == ""
      assert result.exit_code == 0
    end

    test "single line without newline" do
      bash = JustBash.new(files: %{"/data.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "awk '{print $1}' /data.txt")
      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end

    test "line with only whitespace" do
      bash = JustBash.new(files: %{"/data.txt" => "   \n"})
      {result, _} = JustBash.exec(bash, "awk '{print NF}' /data.txt")
      assert result.stdout == "0\n"
      assert result.exit_code == 0
    end

    test "very long field" do
      long_str = String.duplicate("a", 1000)
      bash = JustBash.new(files: %{"/data.txt" => long_str <> "\n"})
      {result, _} = JustBash.exec(bash, "awk '{print length($1)}' /data.txt")
      assert result.stdout == "1000\n"
      assert result.exit_code == 0
    end

    test "special characters in data" do
      bash = JustBash.new(files: %{"/data.txt" => "hello! @#$% ^&*()\n"})
      {result, _} = JustBash.exec(bash, "awk '{print $1}' /data.txt")
      assert result.stdout == "hello!\n"
      assert result.exit_code == 0
    end

    test "numeric strings comparison" do
      # Field > number pattern not comparing numerically
      bash = JustBash.new(files: %{"/data.txt" => "10\n2\n100\n"})
      {result, _} = JustBash.exec(bash, "awk '$1>5{print}' /data.txt")
      assert result.stdout == "10\n100\n"
      assert result.exit_code == 0
    end

    test "uninitialized variable defaults to empty/zero" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk '{print x + 5}' /data.txt")
      assert result.stdout == "5\n"
      assert result.exit_code == 0
    end
  end

  describe "loops" do
    test "for loop basic" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{for(i=1;i<=3;i++)print i}'")
      assert result.stdout == "1\n2\n3\n"
    end

    test "for loop with compound body" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})

      {result, _} =
        JustBash.exec(bash, "awk 'BEGIN{sum=0; for(i=1;i<=5;i++){sum+=i}; print sum}'")

      assert result.stdout == "15\n"
    end

    test "while loop basic" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{i=1; while(i<=3){print i; i++}}'")
      assert result.stdout == "1\n2\n3\n"
    end

    test "while loop with break" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})

      {result, _} =
        JustBash.exec(bash, "awk 'BEGIN{i=1; while(i<=10){if(i>3)break; print i; i++}}'")

      assert result.stdout == "1\n2\n3\n"
    end

    test "while loop with continue" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN{i=0; while(i<5){i++; if(i==3)continue; print i}}'"
        )

      assert result.stdout == "1\n2\n4\n5\n"
    end

    test "nested for loops" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN{for(i=1;i<=2;i++){for(j=1;j<=2;j++){print i,j}}}'"
        )

      assert result.stdout == "1 1\n1 2\n2 1\n2 2\n"
    end
  end

  describe "arrays" do
    test "array assignment and access" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{a["x"]=5; print a["x"]}'|)
      assert result.stdout == "5\n"
    end

    test "array increment" do
      bash = JustBash.new(files: %{"/data.txt" => "a\na\nb\na\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{count[$1]++} END{print count["a"]}' /data.txt|)
      assert result.stdout == "3\n"
    end

    test "for-in loop over array" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})

      {result, _} =
        JustBash.exec(
          bash,
          ~s|awk 'BEGIN{a[1]="one"; a[2]="two"; for(k in a){print k, a[k]}}'|
        )

      # Order of keys is not guaranteed, so check both values are present
      assert result.stdout =~ "one"
      assert result.stdout =~ "two"
    end

    test "in operator" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{a[1]=1; print (1 in a), (2 in a)}'|)
      assert result.stdout == "1 0\n"
    end

    test "delete array element" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})

      {result, _} =
        JustBash.exec(
          bash,
          ~s|awk 'BEGIN{a[1]=1; a[2]=2; delete a[1]; print (1 in a), (2 in a)}'|
        )

      assert result.stdout == "0 1\n"
    end
  end

  describe "control flow" do
    test "next skips to next record" do
      bash = JustBash.new(files: %{"/data.txt" => "1\n2\n3\n4\n"})
      {result, _} = JustBash.exec(bash, "awk '$1==2{next} {print}' /data.txt")
      assert result.stdout == "1\n3\n4\n"
    end

    test "exit terminates processing" do
      bash = JustBash.new(files: %{"/data.txt" => "1\n2\n3\n4\n"})
      {result, _} = JustBash.exec(bash, "awk '{print; if(NR==2)exit}' /data.txt")
      assert result.stdout == "1\n2\n"
    end

    test "exit with code" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{exit 42}'")
      assert result.exit_code == 42
    end
  end

  describe "operators" do
    test "modulo operator" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print 17 % 5}'")
      assert result.stdout == "2\n"
    end

    test "power operator with ^" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print 2^10}'")
      assert result.stdout == "1024\n"
    end

    test "power operator with **" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print 2**3}'")
      assert result.stdout == "8\n"
    end

    test "logical AND" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print (1 && 1), (1 && 0), (0 && 1)}'")
      assert result.stdout == "1 0 0\n"
    end

    test "logical OR" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print (1 || 0), (0 || 1), (0 || 0)}'")
      assert result.stdout == "1 1 0\n"
    end

    test "logical NOT" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print !0, !1, !\"\", !\"x\"}'")
      assert result.stdout == "1 0 1 0\n"
    end

    test "compound assignment -=" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{x=10; x-=3; print x}'")
      assert result.stdout == "7\n"
    end

    test "compound assignment *=" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{x=5; x*=3; print x}'")
      assert result.stdout == "15\n"
    end

    test "compound assignment /=" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{x=20; x/=4; print x}'")
      assert result.stdout == "5\n"
    end

    test "pre-increment ++x" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{x=5; ++x; print x}'")
      assert result.stdout == "6\n"
    end

    test "post-decrement x--" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{x=5; x--; print x}'")
      assert result.stdout == "4\n"
    end

    test "pre-decrement --x" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{x=5; --x; print x}'")
      assert result.stdout == "4\n"
    end
  end

  describe "math functions" do
    test "int() truncates to integer" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print int(3.7), int(-3.7)}'")
      assert result.stdout == "3 -3\n"
    end

    test "sqrt() calculates square root" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print int(sqrt(16))}'")
      assert result.stdout == "4\n"
    end

    test "sin() and cos()" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print int(sin(0)), int(cos(0))}'")
      assert result.stdout == "0 1\n"
    end

    test "exp() and log()" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{print int(exp(0)), int(log(1))}'")
      assert result.stdout == "1 0\n"
    end

    test "rand() returns value between 0 and 1" do
      bash = JustBash.new(files: %{"/data.txt" => "x\n"})
      {result, _} = JustBash.exec(bash, "awk 'BEGIN{r=rand(); print (r>=0 && r<1)}'")
      assert result.stdout == "1\n"
    end
  end
end
