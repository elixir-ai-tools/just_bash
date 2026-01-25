defmodule JustBash.BashComparison.AwkTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  describe "awk field access comparison" do
    test "awk print field" do
      compare_bash("echo 'a b c' | awk '{print $2}'")
    end

    test "awk print first field" do
      compare_bash("echo 'hello world' | awk '{print $1}'")
    end

    test "awk print entire line with $0" do
      compare_bash("echo 'hello world' | awk '{print $0}'")
    end

    test "awk print multiple fields" do
      compare_bash("echo 'a b c d' | awk '{print $1, $3}'")
    end

    test "awk access field beyond NF" do
      compare_bash("echo 'a b c' | awk '{print $10}'")
    end

    test "awk print $NF (last field)" do
      compare_bash("echo 'a b c d' | awk '{print $NF}'")
    end
  end

  describe "awk field separator comparison" do
    test "awk with field separator" do
      compare_bash("echo 'a,b,c' | awk -F, '{print $2}'")
    end

    test "awk with colon separator" do
      compare_bash("echo 'x:y:z' | awk -F: '{print $2}'")
    end

    test "awk with tab separator" do
      compare_bash("printf 'a\\tb\\tc\\n' | awk -F'\\t' '{print $2}'")
    end

    test "awk default whitespace splitting collapses spaces" do
      compare_bash("echo 'a    b    c' | awk '{print $2}'")
    end
  end

  describe "awk built-in variables comparison" do
    test "awk NR line number" do
      compare_bash("echo -e 'a\\nb' | awk '{print NR, $0}'")
    end

    test "awk NF field count" do
      compare_bash("echo 'a b c d' | awk '{print NF}'")
    end

    test "awk NF with varying fields per line" do
      compare_bash("echo -e 'one\\ntwo three\\na b c d' | awk '{print NF}'")
    end

    test "awk NF is 0 for empty line" do
      compare_bash("echo '' | awk '{print NF}'")
    end

    test "awk FS variable in BEGIN" do
      compare_bash("echo 'a,b,c' | awk 'BEGIN{FS=\",\"}{print $2}'")
    end

    test "awk OFS variable" do
      compare_bash("echo 'a b c' | awk 'BEGIN{OFS=\"-\"}{print $1, $2, $3}'")
    end

    test "awk ORS variable" do
      compare_bash("echo -e 'a\\nb' | awk 'BEGIN{ORS=\";\"}{print $0}'")
    end
  end

  describe "awk BEGIN and END comparison" do
    test "awk sum in END block" do
      compare_bash("echo -e '1\\n2\\n3' | awk '{s+=$1} END {print s}'")
    end

    test "awk BEGIN block before processing" do
      compare_bash("echo 'x' | awk 'BEGIN{print \"start\"}{print $0}'")
    end

    test "awk END block after processing" do
      compare_bash("echo -e 'a\\nb' | awk '{print $0}END{print \"done\"}'")
    end

    test "awk BEGIN only no input" do
      compare_bash("awk 'BEGIN{print \"hello\"}'")
    end

    test "awk count lines in END" do
      compare_bash("echo -e 'a\\nb\\nc' | awk '{count++}END{print count}'")
    end

    test "awk multiple BEGIN blocks" do
      compare_bash("awk 'BEGIN{print \"a\"}BEGIN{print \"b\"}'")
    end

    test "awk multiple END blocks" do
      compare_bash("echo 'x' | awk 'END{print \"a\"}END{print \"b\"}'")
    end
  end

  describe "awk pattern matching comparison" do
    test "awk regex pattern filter" do
      compare_bash("echo -e 'apple\\nbanana\\napricot' | awk '/^a/{print}'")
    end

    test "awk regex pattern without action" do
      compare_bash("echo -e 'foo\\nbar\\nbaz' | awk '/ba/'")
    end

    test "awk NR condition ==" do
      compare_bash("echo -e 'line1\\nline2\\nline3' | awk 'NR==2{print}'")
    end

    test "awk NR condition >" do
      compare_bash("echo -e 'line1\\nline2\\nline3' | awk 'NR>1{print}'")
    end

    test "awk NR condition <" do
      compare_bash("echo -e 'line1\\nline2\\nline3' | awk 'NR<3{print}'")
    end

    test "awk field equality condition" do
      compare_bash("echo -e 'yes hello\\nno goodbye\\nyes world' | awk '$1==\"yes\"{print $2}'")
    end

    test "awk field regex match ~" do
      compare_bash("echo -e 'abc 1\\nxyz 2\\nabc 3' | awk '$1 ~ /^a/{print $2}'")
    end

    test "awk field > numeric condition" do
      compare_bash("echo -e '5\\n15\\n25' | awk '$1>10{print}'")
    end

    test "awk field >= numeric condition" do
      compare_bash("echo -e '5\\n10\\n15' | awk '$1>=10{print}'")
    end
  end

  describe "awk arithmetic comparison" do
    test "awk addition" do
      compare_bash("echo '10 20' | awk '{print $1 + $2}'")
    end

    test "awk subtraction" do
      compare_bash("echo '10 3' | awk '{print $1 - $2}'")
    end

    test "awk multiplication" do
      compare_bash("echo '6 7' | awk '{print $1 * $2}'")
    end

    test "awk division" do
      compare_bash("echo '20 4' | awk '{print $1 / $2}'")
    end

    test "awk modulo" do
      compare_bash("awk 'BEGIN{print 17 % 5}'")
    end

    test "awk power with ^" do
      compare_bash("awk 'BEGIN{print 2^10}'")
    end

    test "awk compound += assignment" do
      compare_bash("echo -e '10\\n20\\n30' | awk 'BEGIN{sum=0}{sum+=$1}END{print sum}'")
    end

    test "awk compound -= assignment" do
      compare_bash("awk 'BEGIN{x=10; x-=3; print x}'")
    end

    test "awk compound *= assignment" do
      compare_bash("awk 'BEGIN{x=5; x*=3; print x}'")
    end

    test "awk compound /= assignment" do
      compare_bash("awk 'BEGIN{x=20; x/=4; print x}'")
    end

    test "awk increment ++" do
      compare_bash("awk 'BEGIN{x=5; x++; print x}'")
    end

    test "awk pre-increment ++x" do
      compare_bash("awk 'BEGIN{x=5; ++x; print x}'")
    end

    test "awk decrement --" do
      compare_bash("awk 'BEGIN{x=5; x--; print x}'")
    end

    test "awk pre-decrement --x" do
      compare_bash("awk 'BEGIN{x=5; --x; print x}'")
    end
  end

  describe "awk string functions comparison" do
    test "awk length() no argument" do
      compare_bash("echo 'hello' | awk '{print length()}'")
    end

    test "awk length() with argument" do
      compare_bash("echo 'hello world' | awk '{print length($1)}'")
    end

    test "awk substr() with start only" do
      compare_bash("echo 'hello' | awk '{print substr($0, 3)}'")
    end

    test "awk substr() with start and length" do
      compare_bash("echo 'hello world' | awk '{print substr($0, 1, 5)}'")
    end

    test "awk tolower()" do
      compare_bash("echo 'HELLO World' | awk '{print tolower($0)}'")
    end

    test "awk toupper()" do
      compare_bash("echo 'hello World' | awk '{print toupper($0)}'")
    end

    test "awk index() finds substring" do
      compare_bash("echo 'hello world' | awk '{print index($0, \"wor\")}'")
    end

    test "awk index() not found" do
      compare_bash("echo 'hello world' | awk '{print index($0, \"xyz\")}'")
    end

    test "awk sprintf() basic" do
      compare_bash("awk 'BEGIN{s=sprintf(\"%05d\", 42); print s}'")
    end

    test "awk sprintf() with string" do
      compare_bash("awk 'BEGIN{s=sprintf(\"Hello %s!\", \"World\"); print s}'")
    end
  end

  describe "awk printf comparison" do
    test "awk printf %s" do
      compare_bash("echo 'hello world' | awk '{printf \"%s!\\n\", $1}'")
    end

    test "awk printf %d" do
      compare_bash("echo '42' | awk '{printf \"num: %d\\n\", $1}'")
    end

    test "awk printf width specifier" do
      compare_bash("awk 'BEGIN{printf \"%5d\\n\", 42}'")
    end

    test "awk printf left justify" do
      compare_bash("awk 'BEGIN{printf \"%-5d|\\n\", 42}'")
    end

    test "awk printf float precision" do
      compare_bash("awk 'BEGIN{printf \"%.2f\\n\", 3.14159}'")
    end

    test "awk printf multiple arguments" do
      compare_bash("echo 'John 25' | awk '{printf \"%s is %d years old\\n\", $1, $2}'")
    end

    test "awk printf with dollar sign" do
      compare_bash("echo 'Alice 1000' | awk '{printf \"%-10s $%d\\n\", $1, $2}'")
    end
  end

  describe "awk gsub and sub comparison" do
    test "awk gsub replaces all" do
      compare_bash("echo 'hello world' | awk '{gsub(/o/, \"0\"); print}'")
    end

    test "awk sub replaces first only" do
      compare_bash("echo 'hello world' | awk '{sub(/o/, \"0\"); print}'")
    end

    test "awk gsub on specific field" do
      compare_bash("echo 'foo bar' | awk '{gsub(/o/, \"0\", $1); print $1}'")
    end

    test "awk gsub multiple chars" do
      compare_bash("echo 'aaa bbb aaa' | awk '{gsub(/a/, \"x\"); print}'")
    end
  end

  describe "awk if-else comparison" do
    test "awk simple if condition" do
      compare_bash(
        "echo -e '5\\n15\\n25' | awk '{if ($1 > 10) print \"big\"; else print \"small\"}'"
      )
    end

    test "awk if with == comparison" do
      compare_bash(
        "echo -e '1\\n2\\n1' | awk '{if ($1 == 1) print \"one\"; else print \"other\"}'"
      )
    end

    test "awk if with string comparison" do
      compare_bash(
        "echo -e 'yes\\nno\\nyes' | awk '{if ($1 == \"yes\") print \"Y\"; else print \"N\"}'"
      )
    end
  end

  describe "awk ternary operator comparison" do
    test "awk ternary in print" do
      compare_bash("echo -e '5\\n15' | awk '{print ($1 > 10) ? \"big\" : \"small\"}'")
    end

    test "awk ternary with arithmetic" do
      compare_bash("awk 'BEGIN{x=5; print (x>3) ? x*2 : x}'")
    end
  end

  describe "awk loops comparison" do
    test "awk for loop basic" do
      compare_bash("awk 'BEGIN{for(i=1;i<=3;i++)print i}'")
    end

    test "awk for loop with sum" do
      compare_bash("awk 'BEGIN{sum=0; for(i=1;i<=5;i++){sum+=i}; print sum}'")
    end

    test "awk while loop basic" do
      compare_bash("awk 'BEGIN{i=1; while(i<=3){print i; i++}}'")
    end

    test "awk while with break" do
      compare_bash("awk 'BEGIN{i=1; while(i<=10){if(i>3)break; print i; i++}}'")
    end

    test "awk while with continue" do
      compare_bash("awk 'BEGIN{i=0; while(i<5){i++; if(i==3)continue; print i}}'")
    end

    test "awk nested for loops" do
      compare_bash("awk 'BEGIN{for(i=1;i<=2;i++){for(j=1;j<=2;j++){print i,j}}}'")
    end
  end

  describe "awk arrays comparison" do
    test "awk array assignment and access" do
      compare_bash("awk 'BEGIN{a[\"x\"]=5; print a[\"x\"]}'")
    end

    test "awk array increment" do
      compare_bash("echo -e 'a\\na\\nb\\na' | awk '{count[$1]++} END{print count[\"a\"]}'")
    end

    test "awk in operator" do
      compare_bash("awk 'BEGIN{a[1]=1; print (1 in a), (2 in a)}'")
    end

    test "awk delete array element" do
      compare_bash("awk 'BEGIN{a[1]=1; a[2]=2; delete a[1]; print (1 in a), (2 in a)}'")
    end

    test "awk array with string keys" do
      compare_bash("awk 'BEGIN{a[\"foo\"]=\"bar\"; print a[\"foo\"]}'")
    end
  end

  describe "awk control flow comparison" do
    test "awk next skips to next record" do
      compare_bash("echo -e '1\\n2\\n3\\n4' | awk '\$1==2{next} {print}'")
    end

    test "awk exit terminates processing" do
      compare_bash("echo -e '1\\n2\\n3\\n4' | awk '{print; if(NR==2)exit}'")
    end

    test "awk exit with code" do
      compare_bash("awk 'BEGIN{exit 42}'; echo $?")
    end
  end

  describe "awk logical operators comparison" do
    test "awk logical AND" do
      compare_bash("awk 'BEGIN{print (1 && 1), (1 && 0), (0 && 1)}'")
    end

    test "awk logical OR" do
      compare_bash("awk 'BEGIN{print (1 || 0), (0 || 1), (0 || 0)}'")
    end

    test "awk logical NOT" do
      compare_bash("awk 'BEGIN{print !0, !1}'")
    end
  end

  describe "awk math functions comparison" do
    test "awk int() truncates" do
      compare_bash("awk 'BEGIN{print int(3.7), int(-3.7)}'")
    end

    test "awk sqrt()" do
      compare_bash("awk 'BEGIN{print int(sqrt(16))}'")
    end

    test "awk sin() and cos()" do
      compare_bash("awk 'BEGIN{print int(sin(0)), int(cos(0))}'")
    end

    test "awk exp() and log()" do
      compare_bash("awk 'BEGIN{print int(exp(0)), int(log(1))}'")
    end
  end

  describe "awk real-world patterns comparison" do
    test "awk sum column values" do
      compare_bash("echo -e 'item1 10\\nitem2 20\\nitem3 30' | awk '{sum+=$2}END{print sum}'")
    end

    test "awk calculate average" do
      compare_bash("echo -e '10\\n20\\n30' | awk '{sum+=$1; count++}END{print sum/count}'")
    end

    test "awk find max value" do
      compare_bash(
        "echo -e '10\\n25\\n15\\n30\\n5' | awk 'BEGIN{max=0}$1>max{max=$1}END{print max}'"
      )
    end

    test "awk find min value" do
      compare_bash(
        "echo -e '10\\n25\\n15\\n30\\n5' | awk 'BEGIN{min=9999}$1<min{min=$1}END{print min}'"
      )
    end

    test "awk skip header row" do
      compare_bash("echo -e 'name,age\\nAlice,30\\nBob,25' | awk -F, 'NR>1{print $1}'")
    end

    test "awk count pattern matches" do
      compare_bash(
        "echo -e 'INFO: start\\nERROR: fail\\nINFO: done\\nERROR: crash' | awk '/ERROR/{count++}END{print count}'"
      )
    end

    test "awk transform to uppercase" do
      compare_bash("echo -e 'john doe\\njane smith' | awk '{print toupper($1), toupper($2)}'")
    end
  end

  describe "awk edge cases comparison" do
    test "awk empty input" do
      compare_bash("echo -n '' | awk '{print $1}'")
    end

    test "awk single line no newline" do
      compare_bash("echo -n 'hello' | awk '{print $1}'")
    end

    test "awk special characters in data" do
      compare_bash("echo 'hello! @#' | awk '{print $1}'")
    end

    test "awk uninitialized variable is zero" do
      compare_bash("echo 'x' | awk '{print x + 5}'")
    end

    test "awk string coercion in arithmetic" do
      compare_bash("echo '10abc 5' | awk '{print $1 + $2}'")
    end
  end
end
