IO.puts("\nJustBash Demo\n" <> String.duplicate("=", 50))

bash =
  JustBash.new(
    files: %{
      "/data/users.txt" => "alice\nbob\ncharlie\nalice\nbob\nalice",
      "/data/numbers.txt" => "5\n3\n8\n1\n9\n2\n7",
      "/app/config.env" => "DATABASE_URL=postgres://localhost/mydb\nPORT=3000"
    }
  )

run = fn bash, cmd ->
  IO.puts("\n$ #{cmd}")
  {result, bash} = JustBash.exec(bash, cmd)
  if result.stdout != "", do: IO.write(result.stdout)
  if result.stderr != "", do: IO.puts("stderr: #{result.stderr}")
  bash
end

IO.puts("\n\n[File Operations & Pipelines]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, "ls /data")
bash = run.(bash, "cat /data/users.txt | sort | uniq -c | sort -rn")
bash = run.(bash, "cat /data/numbers.txt | sort -n | head -3")

IO.puts("\n\n[FizzBuzz - for loop + arithmetic + conditionals]")
IO.puts(String.duplicate("-", 50))

{result, bash} =
  JustBash.exec(bash, """
  for i in $(seq 1 15); do
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

IO.puts("\n$ # FizzBuzz 1-15")
IO.write(result.stdout)

IO.puts("\n\n[Arithmetic Expansion]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, ~S[echo "2 + 2 = $((2 + 2))"])
bash = run.(bash, ~S[echo "2 ** 10 = $((2 ** 10))"])
bash = run.(bash, ~S[echo "Ternary: $((5 > 3 ? 100 : 0))"])
bash = run.(bash, ~S[x=7; echo "x is $x, x squared is $((x * x))"])
bash = run.(bash, ~S[echo "Factorial 5! = $((5 * 4 * 3 * 2 * 1))"])

IO.puts("\n\n[Variable Expansion]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, ~S[name="World"; echo "Hello, $name!"])
bash = run.(bash, ~S[echo "Default: ${UNDEFINED:-default_value}"])
bash = run.(bash, ~S[greeting="Hello"; echo "Length: ${#greeting}"])

IO.puts("\n\n[Command Substitution]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, ~S[echo "Files in /data: $(ls /data | wc -l)"])
bash = run.(bash, ~S[echo "Today is $(date)"])

IO.puts("\n\n[Conditionals & Tests]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, "[ -f /data/users.txt ] && echo \"users.txt exists!\"")
bash = run.(bash, "[ -d /data ] && echo \"/data is a directory\"")
bash = run.(bash, "test 5 -gt 3 && echo \"5 is greater than 3\"")

IO.puts("\n\n[While Loop - countdown]")
IO.puts(String.duplicate("-", 50))

{result, bash} =
  JustBash.exec(bash, """
  n=5
  while [ $n -gt 0 ]; do
    echo "T-minus $n..."
    n=$((n - 1))
  done
  echo "Liftoff!"
  """)

IO.puts("\n$ # Countdown")
IO.write(result.stdout)

IO.puts("\n\n[File Manipulation]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, "mkdir -p /tmp/myproject/src")
bash = run.(bash, "echo \"console.log('hello')\" > /tmp/myproject/src/index.js")
bash = run.(bash, "cat /tmp/myproject/src/index.js")
bash = run.(bash, "ls -la /tmp/myproject/src")

IO.puts("\n\n[Text Processing]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, "grep alice /data/users.txt | wc -l")
bash = run.(bash, "echo \"hello world\" | tr 'a-z' 'A-Z'")

IO.puts("\n\n[Short-circuit Evaluation]")
IO.puts(String.duplicate("-", 50))

bash = run.(bash, "true && echo \"AND: first was true\"")
bash = run.(bash, "false || echo \"OR: first was false\"")
_bash = run.(bash, "false && echo \"never printed\" || echo \"fallback executed\"")

IO.puts("\n\n" <> String.duplicate("=", 50))
IO.puts("All examples completed!")
IO.puts("This all ran in a sandboxed virtual filesystem.")
IO.puts(String.duplicate("=", 50) <> "\n")
