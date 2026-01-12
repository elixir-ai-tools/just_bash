IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("  JustBash - A Sandboxed Bash Environment for Elixir")
IO.puts(String.duplicate("=", 60))

bash =
  JustBash.new(
    files: %{
      "/data/users.csv" =>
        "name,role,salary\nalice,engineer,95000\nbob,manager,120000\ncharlie,engineer,85000\ndiana,designer,90000\neve,engineer,100000",
      "/data/logs.txt" =>
        "2024-01-15 ERROR Connection failed\n2024-01-15 INFO Server started\n2024-01-16 WARN High memory usage\n2024-01-16 ERROR Disk full\n2024-01-17 INFO Backup complete",
      "/data/numbers.txt" => "42\n17\n99\n3\n256\n8\n1024"
    }
  )

run = fn bash, cmd ->
  IO.puts("\n  $ #{cmd}")
  {result, bash} = JustBash.exec(bash, cmd)

  if result.stdout != "" do
    result.stdout
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&IO.puts("  #{&1}"))
  end

  if result.stderr != "", do: IO.puts("  stderr: #{result.stderr}")
  bash
end

IO.puts("\n\n[1] BRACE EXPANSION - Generate multiple items from patterns")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "echo {a,b,c}")
bash = run.(bash, "echo {1..5}")
bash = run.(bash, "echo {a..f}")
bash = run.(bash, "echo file{1,2,3}.txt")
bash = run.(bash, "echo {mon,tues,wednes,thurs,fri}day")
bash = run.(bash, "echo {1..3}{a,b}")

IO.puts("\n\n[2] NESTED ARITHMETIC - Complex math with proper nesting")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "echo \"Nested: \\$((1 + (2 * (3 + 4))))\"")
bash = run.(bash, "echo \"Powers: \\$((2 ** 10))\"")
bash = run.(bash, "echo \"Modulo: \\$((17 % 5))\"")
bash = run.(bash, "echo \"Ternary: \\$((10 > 5 ? 100 : 0))\"")

IO.puts("\n\n[3] NESTED PARAMETER EXPANSION - Defaults within defaults")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "echo \"Fallback: \\${X:-\\${Y:-final}}\"")
bash = run.(bash, "text=hello; echo \"Upper: \\${text^^}\"")
bash = run.(bash, "path=/usr/local/bin/script.sh; echo \"Base: \\${path##*/}\"")
bash = run.(bash, "file=doc.tar.gz; echo \"Stem: \\${file%.*}\"")
bash = run.(bash, "str=hello; echo \"Slice: \\${str:1:3}\"")

IO.puts("\n\n[4] GLOB EXPANSION - Pattern matching")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "ls /data")
bash = run.(bash, "echo /data/*.txt")
bash = run.(bash, "echo /data/*")

IO.puts("\n\n[5] PIPELINES & TEXT PROCESSING")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "cat /data/users.csv | head -1")
bash = run.(bash, "grep ERROR /data/logs.txt | wc -l")
bash = run.(bash, "cat /data/numbers.txt | sort -n | tail -3")
bash = run.(bash, "echo 'hello world' | tr 'a-z' 'A-Z'")

IO.puts("\n\n[6] SED - Stream editing")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "echo 'hello world' | sed 's/world/universe/'")
bash = run.(bash, "echo 'aaa bbb ccc' | sed 's/b/X/g'")

IO.puts("\n\n[7] CONDITIONALS & TESTS")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "test -f /data/users.csv && echo 'users.csv exists'")
bash = run.(bash, "test 10 -gt 5 && echo '10 > 5'")
bash = run.(bash, "[ -d /data ] && echo '/data is a directory'")

IO.puts("\n\n[8] LOOPS - For with brace expansion")
IO.puts(String.duplicate("-", 60))

{result, bash} =
  JustBash.exec(bash, """
  for fruit in apple banana cherry; do
    echo "I like $fruit"
  done
  """)

IO.puts("\n  $ for fruit in apple banana cherry; do echo ...; done")
String.split(result.stdout, "\n") |> Enum.reject(&(&1 == "")) |> Enum.each(&IO.puts("  #{&1}"))

{result, bash} =
  JustBash.exec(bash, """
  sum=0
  for n in $(cat /data/numbers.txt); do
    sum=$((sum + n))
  done
  echo "Sum of all numbers: $sum"
  """)

IO.puts("\n  $ # Sum all numbers from file")
String.split(result.stdout, "\n") |> Enum.reject(&(&1 == "")) |> Enum.each(&IO.puts("  #{&1}"))

IO.puts("\n\n[9] CASE STATEMENTS - Pattern matching")
IO.puts(String.duplicate("-", 60))

{result, bash} =
  JustBash.exec(bash, """
  for file in data.txt users.csv run.sh image.png; do
    case "$file" in
      *.txt) echo "$file -> text" ;;
      *.csv) echo "$file -> csv" ;;
      *.sh)  echo "$file -> script" ;;
      *)     echo "$file -> unknown" ;;
    esac
  done
  """)

IO.puts("\n  $ case \"\\$file\" in *.txt) ... ;; esac")
String.split(result.stdout, "\n") |> Enum.reject(&(&1 == "")) |> Enum.each(&IO.puts("  #{&1}"))

IO.puts("\n\n[10] HEREDOCS - Multi-line strings with expansion")
IO.puts(String.duplicate("-", 60))

{result, bash} =
  JustBash.exec(bash, """
  name="World"
  count=42
  cat <<EOF
  Hello, $name!
  The answer is $count.
  Today is $(date).
  EOF
  """)

IO.puts("\n  $ cat <<EOF ...")
String.split(result.stdout, "\n") |> Enum.reject(&(&1 == "")) |> Enum.each(&IO.puts("  #{&1}"))

IO.puts("\n\n[11] XARGS - Build and execute commands")
IO.puts(String.duplicate("-", 60))

bash = run.(bash, "echo -e 'one\\ntwo\\nthree' | xargs echo 'Items:'")
bash = run.(bash, "echo '1 2 3 4 5' | xargs -n 2 echo")

IO.puts("\n\n[12] FIZZBUZZ - Combining features")
IO.puts(String.duplicate("-", 60))

{result, _bash} =
  JustBash.exec(bash, """
  for i in {1..15}; do
    if [ $((i % 15)) -eq 0 ]; then
      echo "FizzBuzz"
    elif [ $((i % 3)) -eq 0 ]; then
      echo "Fizz"
    elif [ $((i % 5)) -eq 0 ]; then
      echo "Buzz"
    else
      echo $i
    fi
  done
  """)

IO.puts("\n  $ for i in {1..15}; do if [ \\$((i % 15)) -eq 0 ]; then ...")
String.split(result.stdout, "\n") |> Enum.reject(&(&1 == "")) |> Enum.each(&IO.puts("  #{&1}"))

IO.puts("\n\n" <> String.duplicate("=", 60))
IO.puts("  All examples executed in a sandboxed virtual filesystem!")
IO.puts("  No real files were touched. Perfect for AI agents.")
IO.puts(String.duplicate("=", 60) <> "\n")
