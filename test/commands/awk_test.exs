defmodule JustBash.Commands.AwkTest do
  @moduledoc """
  Comprehensive tests for the awk command.

  Based on Vercel's just-bash test suite with additional tests
  for edge cases and specific features.
  """
  use ExUnit.Case, async: true

  alias JustBash.Fs

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

  describe "multi-statement blocks" do
    test "if body with multiple statements in braces" do
      bash = JustBash.new(files: %{"/data.txt" => "1\n2\n3\n"})

      cmd = "awk '{if ($1 > 1) { count++; print \"big:\", $1 }}' /data.txt"
      {result, _} = JustBash.exec(bash, cmd)

      assert result.stdout == "big: 2\nbig: 3\n"
    end

    test "if-else with multi-statement bodies" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\n"})

      cmd =
        "awk '{if (NR == 1) { x = \"first\"; print x } else { x = \"other\"; print x }}' /data.txt"

      {result, _} = JustBash.exec(bash, cmd)

      assert result.stdout == "first\nother\n"
    end
  end

  describe "not operator in conditions" do
    test "negation with ! in awk condition" do
      bash = JustBash.new(files: %{"/data.txt" => "hello\nworld\n"})

      cmd = "awk 'BEGIN{first=1} {if (!first) print \"not first:\", $0; first=0}' /data.txt"
      {result, _} = JustBash.exec(bash, cmd)

      assert result.stdout == "not first: world\n"
    end

    test "negation with ! in pattern" do
      bash = JustBash.new(files: %{"/data.txt" => "yes\nno\nyes\n"})
      {result, _} = JustBash.exec(bash, "awk '!/no/' /data.txt")
      assert result.stdout == "yes\nyes\n"
    end
  end

  describe "pre-increment and post-increment as expressions" do
    test "pre-increment ++n used as array index" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\nc\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ arr[++n] = $0 } END { for (i=1; i<=n; i++) print arr[i] }' /data.txt"
        )

      assert result.stdout == "a\nb\nc\n"
    end

    test "post-increment n++ used as array index" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\nc\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ arr[n++] = $0 } END { for (i=0; i<n; i++) print arr[i] }' /data.txt"
        )

      assert result.stdout == "a\nb\nc\n"
    end

    test "pre-increment in arithmetic expression" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(
          bash,
          "echo 'x' | awk 'BEGIN { n=5 } { print ++n }'"
        )

      assert result.stdout == "6\n"
    end

    test "post-increment in arithmetic expression" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(
          bash,
          "echo 'x' | awk 'BEGIN { n=5 } { print n++ }'"
        )

      assert result.stdout == "5\n"
    end
  end

  describe "print append redirection" do
    test "print >> file appends output" do
      bash = JustBash.new()

      {result, bash} =
        JustBash.exec(
          bash,
          "echo 'hello' | awk '{ print $0 >> \"/tmp/out.txt\" }'"
        )

      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /tmp/out.txt")
      assert result2.stdout == "hello\n"
    end

    test "print >> file appends multiple lines" do
      bash = JustBash.new(files: %{"/data.txt" => "a\nb\nc\n"})

      {result, bash} =
        JustBash.exec(
          bash,
          "awk '{ print $0 >> \"/tmp/out.txt\" }' /data.txt"
        )

      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /tmp/out.txt")
      assert result2.stdout == "a\nb\nc\n"
    end
  end

  describe "system() function" do
    test "system() executes a command and returns exit code as statement" do
      bash = JustBash.new(files: %{"/data.txt" => "hello\n"})

      {result, bash} =
        JustBash.exec(bash, "awk 'BEGIN { system(\"mkdir -p /output\") }' /data.txt")

      assert result.exit_code == 0
      {result2, _} = JustBash.exec(bash, "ls /output")
      assert result2.exit_code == 0
    end

    test "system() return value is the exit code" do
      bash = JustBash.new(files: %{"/data.txt" => "hello\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN { rc = system(\"echo ok\"); print \"rc=\" rc }' /data.txt"
        )

      assert result.exit_code == 0
      assert result.stdout =~ "rc=0"
    end
  end

  describe "match() function" do
    test "2-arg match returns position on match" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, "awk '{print match($0, /wor/)}' /data.txt")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "7"
    end

    test "2-arg match returns 0 on no match" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, "awk '{print match($0, /xyz/)}' /data.txt")
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "0"
    end

    test "2-arg match sets RSTART and RLENGTH" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})

      {result, _} =
        JustBash.exec(bash, "awk '{match($0, /wor/); print RSTART, RLENGTH}' /data.txt")

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "7 3"
    end

    test "2-arg match sets RSTART=0 RLENGTH=-1 on no match" do
      bash = JustBash.new(files: %{"/data.txt" => "hello world\n"})

      {result, _} =
        JustBash.exec(bash, "awk '{match($0, /xyz/); print RSTART, RLENGTH}' /data.txt")

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "0 -1"
    end

    test "3-arg match populates array with capture groups" do
      bash = JustBash.new(files: %{"/data.txt" => "foo123bar\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{match($0, /([a-z]+)([0-9]+)/, arr); print arr[1], arr[2]}' /data.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "foo 123"
    end

    test "3-arg match populates arr[0] with full match" do
      bash = JustBash.new(files: %{"/data.txt" => "foo123bar\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{match($0, /[0-9]+/, arr); print arr[0]}' /data.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "123"
    end
  end

  describe "getline" do
    test "getline reads from file in BEGIN block" do
      bash = JustBash.new(files: %{"/data.txt" => "hello\nworld\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN { while ((getline line < \"/data.txt\") > 0) print line }'"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello\nworld"
    end

    test "getline reads into variable from file" do
      bash = JustBash.new(files: %{"/a.txt" => "alpha\nbeta\n", "/b.txt" => "one\ntwo\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN { getline x < \"/a.txt\"; getline y < \"/b.txt\"; print x, y }'"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "alpha one"
    end

    test "getline returns 1 on success, 0 at EOF" do
      bash = JustBash.new(files: %{"/data.txt" => "only\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN { r1 = (getline line < \"/data.txt\"); r2 = (getline line < \"/data.txt\"); print r1, r2 }'"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "1 0"
    end
  end

  describe "split() function" do
    test "split as standalone statement populates array" do
      bash = JustBash.new(files: %{"/d.txt" => "a:b:c\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ split($0, parts, \":\"); print parts[1], parts[2], parts[3] }' /d.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "a b c"
    end

    test "split with field and custom separator" do
      bash = JustBash.new(files: %{"/d.txt" => "abc,2024,feat: add mode\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk -F',' '{ split($3, parts, \": \"); print parts[1], parts[2] }' /d.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "feat add mode"
    end

    test "split return value is number of pieces" do
      bash = JustBash.new(files: %{"/d.txt" => "a:b:c\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ n = split($0, parts, \":\"); print n }' /d.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "3"
    end

    test "split with default FS" do
      bash = JustBash.new(files: %{"/d.txt" => "hello world foo\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ split($0, a); print a[1], a[3] }' /d.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello foo"
    end
  end

  describe "regex matching with special characters" do
    test "regex /=/ in condition" do
      bash = JustBash.new(files: %{"/d.txt" => "FOO=bar\nBAZ=qux\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ if ($0 ~ /=/) print \"match:\", $0 }' /d.txt"
        )

      assert result.exit_code == 0
      assert result.stdout == "match: FOO=bar\nmatch: BAZ=qux\n"
    end

    test "field regex match $i ~ /pattern/" do
      bash = JustBash.new(files: %{"/d.txt" => "ENV KEY=val OTHER\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ for(i=1; i<=NF; i++) { if ($i ~ /=/) print $i } }' /d.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "KEY=val"
    end
  end

  describe "generic function call as statement" do
    test "close() as standalone statement" do
      bash =
        JustBash.new(files: %{"/data.txt" => "hello\nworld\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'BEGIN { while ((getline line < \"/data.txt\") > 0) print line; close(\"/data.txt\") }'"
        )

      assert result.exit_code == 0
      assert result.stdout =~ "hello"
    end
  end

  describe "multi-file processing" do
    test "FNR resets per file" do
      bash =
        JustBash.new(
          files: %{
            "/f1.txt" => "a\nb\n",
            "/f2.txt" => "c\nd\n"
          }
        )

      {result, _} =
        JustBash.exec(bash, "awk '{ print FILENAME, FNR, NR }' /f1.txt /f2.txt")

      lines = String.trim(result.stdout) |> String.split("\n")
      assert length(lines) == 4
      # FNR resets for second file, NR doesn't
      assert Enum.at(lines, 0) =~ "1 1"
      assert Enum.at(lines, 1) =~ "2 2"
      assert Enum.at(lines, 2) =~ "1 3"
      assert Enum.at(lines, 3) =~ "2 4"
    end

    test "FNR == NR idiom for two-file join" do
      bash =
        JustBash.new(
          files: %{
            "/lookup.txt" => "a 1\nb 2\nc 3\n",
            "/data.txt" => "b hello\na world\n"
          }
        )

      {result, _} =
        JustBash.exec(
          bash,
          "awk 'FNR == NR { lookup[$1] = $2; next } { print $1, lookup[$1] }' /lookup.txt /data.txt"
        )

      assert result.exit_code == 0
      lines = String.trim(result.stdout) |> String.split("\n")
      assert "b 2" in lines
      assert "a 1" in lines
    end

    test "FILENAME is set correctly per file" do
      bash =
        JustBash.new(
          files: %{
            "/a.txt" => "line1\n",
            "/b.txt" => "line2\n"
          }
        )

      {result, _} =
        JustBash.exec(bash, "awk '{ print FILENAME }' /a.txt /b.txt")

      lines = String.trim(result.stdout) |> String.split("\n")
      assert Enum.at(lines, 0) == "/a.txt"
      assert Enum.at(lines, 1) == "/b.txt"
    end
  end

  describe "asorti() function" do
    test "asorti sorts array indices" do
      bash = JustBash.new(files: %{"/d.txt" => "z 1\na 2\nm 3\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ data[$1] = $2 } END { n = asorti(data, keys); for (i = 1; i <= n; i++) print keys[i] }' /d.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "a\nm\nz"
    end

    test "asorti returns count of elements" do
      bash = JustBash.new(files: %{"/d.txt" => "x\ny\nz\n"})

      {result, _} =
        JustBash.exec(
          bash,
          "awk '{ data[$0] = 1 } END { n = asorti(data, keys); print n }' /d.txt"
        )

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "3"
    end
  end

  describe "printf redirect to variable filename" do
    test "printf with > redirect to variable" do
      bash = JustBash.new(files: %{"/d.txt" => "a,1\nb,2\nc,3\n"})

      {result, updated_bash} =
        JustBash.exec(
          bash,
          "awk -F',' 'BEGIN { f = \"/output.txt\" } { printf \"%s=%s\\n\", $1, $2 > f }' /d.txt"
        )

      assert result.exit_code == 0
      {:ok, content} = Fs.read_file(updated_bash.fs, "/output.txt")
      assert content == "a=1\nb=2\nc=3\n"
    end

    test "printf with >> append redirect to variable" do
      bash = JustBash.new(files: %{"/d.txt" => "x\ny\n"})

      {result, updated_bash} =
        JustBash.exec(
          bash,
          "awk '{ printf \"%s\\n\", $0 >> \"/out.txt\" }' /d.txt"
        )

      assert result.exit_code == 0
      {:ok, content} = Fs.read_file(updated_bash.fs, "/out.txt")
      assert content == "x\ny\n"
    end
  end

  describe "field assignment" do
    test "$1 assignment replaces first field and reconstructs $0" do
      bash = JustBash.new(files: %{"/d.txt" => "hello world\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{$1="goodbye"; print}' /d.txt|)
      assert result.exit_code == 0
      assert result.stdout == "goodbye world\n"
    end

    test "$1 assignment to empty string removes first field" do
      bash = JustBash.new(files: %{"/d.txt" => "a b c\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{$1=""; print}' /d.txt|)
      assert result.exit_code == 0
      assert result.stdout == " b c\n"
    end

    test "$2 assignment changes second field" do
      bash = JustBash.new(files: %{"/d.txt" => "one two three\n"})
      {result, _} = JustBash.exec(bash, ~s|awk '{$2="TWO"; print}' /d.txt|)
      assert result.exit_code == 0
      assert result.stdout == "one TWO three\n"
    end

    test "field assignment with OFS" do
      bash = JustBash.new(files: %{"/d.txt" => "a b c\n"})
      {result, _} = JustBash.exec(bash, ~s|awk 'BEGIN{OFS=","}{$2="X"; print}' /d.txt|)
      assert result.exit_code == 0
      assert result.stdout == "a,X,c\n"
    end
  end
end
