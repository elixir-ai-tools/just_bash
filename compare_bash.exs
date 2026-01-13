# Script to compare JustBash vs real bash
# Run with: mix run compare_bash.exs

defmodule Compare do
  def run_bash(cmd) do
    {output, exit_code} = System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
    {output, exit_code}
  end

  def run_just(cmd) do
    bash = JustBash.new()
    {result, _} = JustBash.exec(bash, cmd)
    {result.stdout <> result.stderr, result.exit_code}
  end

  def compare(cmd) do
    {bash_out, bash_exit} = run_bash(cmd)
    {just_out, just_exit} = run_just(cmd)

    if bash_out == just_out and bash_exit == just_exit do
      :match
    else
      {:diff, bash_out, bash_exit, just_out, just_exit}
    end
  end
end

commands = [
  # echo variations
  "echo hello",
  "echo -n hello",
  "echo -e 'a\\tb'",
  "echo -e 'a\\nb'",

  # printf
  "printf '%s\\n' hello",
  "printf '%d\\n' 42",
  "printf '%.2f\\n' 3.14159",
  "printf '%05d\\n' 42",

  # Variable expansion
  "x=hello; echo $x",
  "x=hello; echo ${x}world",
  "x=hello; echo ${#x}",
  "echo ${undefined:-default}",
  "x=set; echo ${x:+replacement}",
  "x=hello; echo ${x:1:3}",
  "x=file.txt; echo ${x%.txt}",
  "x=file.txt; echo ${x##*.}",

  # Arithmetic
  "echo $((1+2))",
  "echo $((10/3))",
  "echo $((10%3))",
  "echo $((2**8))",
  "x=5; echo $((x*2))",

  # Brace expansion
  "echo {a,b,c}",
  "echo {1..5}",
  "echo {a..e}",
  "echo pre{1,2}post",

  # Quoting
  "echo \"hello world\"",
  "x=test; echo \"$x\"",

  # Command substitution
  "echo $(echo hello)",
  "x=$(echo world); echo $x",

  # Pipes
  "echo hello | cat",
  "echo -e 'b\\na\\nc' | sort",
  "echo hello | tr a-z A-Z",

  # tr
  "echo hello | tr l L",
  "echo hello | tr -d l",
  "echo HELLO | tr A-Z a-z",

  # grep
  "echo -e 'foo\\nbar\\nbaz' | grep bar",
  "echo -e 'foo\\nbar\\nbaz' | grep -v bar",
  "echo -e 'foo\\nbar\\nbaz' | grep -n bar",
  "echo -e 'FOO\\nfoo' | grep -i foo",

  # sed
  "echo hello | sed 's/l/L/'",
  "echo hello | sed 's/l/L/g'",
  "echo -e 'a\\nb\\nc' | sed -n '2p'",
  "echo -e 'a\\nb\\nc' | sed '1d'",

  # awk
  "echo 'a b c' | awk '{print $2}'",
  "echo 'a,b,c' | awk -F, '{print $2}'",
  "echo -e '1\\n2\\n3' | awk '{sum+=$1} END {print sum}'",

  # head/tail
  "echo -e '1\\n2\\n3\\n4\\n5' | head -n 2",
  "echo -e '1\\n2\\n3\\n4\\n5' | tail -n 2",

  # wc
  "echo hello | wc -c",
  "echo -e 'a\\nb\\nc' | wc -l",

  # cut
  "echo 'a,b,c' | cut -d, -f2",
  "echo hello | cut -c1-3",

  # uniq
  "echo -e 'a\\na\\nb\\nb\\nc' | uniq",
  "echo -e 'a\\na\\nb' | uniq -c",

  # sort
  "echo -e 'c\\na\\nb' | sort",
  "echo -e 'c\\na\\nb' | sort -r",
  "echo -e '10\\n2\\n1' | sort -n",

  # Control flow
  "if true; then echo yes; fi",
  "if false; then echo yes; else echo no; fi",
  "for i in 1 2 3; do echo $i; done",
  "x=3; while [ $x -gt 0 ]; do echo $x; x=$((x-1)); done",

  # test/[
  "[ 1 -eq 1 ] && echo equal",
  "[ 1 -lt 2 ] && echo less",
  "[ -n 'hello' ] && echo nonempty",
  "[ -z '' ] && echo empty",

  # Logical operators
  "true && echo yes",
  "false || echo fallback",
  "true && false || echo recovered",

  # seq
  "seq 5",
  "seq 2 5",
  "seq 1 2 10",

  # rev
  "echo hello | rev",

  # basename/dirname
  "basename /path/to/file.txt",
  "dirname /path/to/file.txt",

  # xargs
  "echo 'a b c' | xargs -n1 echo",

  # tee (just output, ignore file)
  "echo hello | tee /dev/null",

  # cat with heredoc
  "cat << 'EOF'\nhello\nworld\nEOF",

  # read
  "echo hello | { read x; echo got $x; }",

  # Multiple statements
  "echo a; echo b; echo c",
  "x=1; y=2; echo $((x+y))",

  # Subshell
  "(echo sub; echo shell)",
  "(x=local; echo $x); echo ${x:-unset}",

  # Exit codes
  "true; echo $?",
  "false; echo $?",

  # Special variables
  # "echo $$",  # PID - will always differ between bash and JustBash

  # Arrays (if supported)
  # "arr=(a b c); echo ${arr[1]}",

  # jq (if available in both)
  "echo '{\"a\":1}' | jq '.a'",
  "echo '[1,2,3]' | jq '.[]'",
  "echo '{\"x\":\"hello\"}' | jq -r '.x'"
]

results =
  Enum.map(commands, fn cmd ->
    {cmd, Compare.compare(cmd)}
  end)

matches = Enum.count(results, fn {_, r} -> r == :match end)
diffs = Enum.filter(results, fn {_, r} -> r != :match end)

IO.puts("=== COMPARISON RESULTS ===")
IO.puts("Matches: #{matches}/#{length(commands)}")
IO.puts("")

if diffs != [] do
  IO.puts("=== DIFFERENCES (#{length(diffs)}) ===")
  IO.puts("")

  Enum.each(diffs, fn {cmd, {:diff, bash_out, bash_exit, just_out, just_exit}} ->
    IO.puts("Command: #{cmd}")
    IO.puts("  Bash:     #{inspect(bash_out)} (exit #{bash_exit})")
    IO.puts("  JustBash: #{inspect(just_out)} (exit #{just_exit})")
    IO.puts("")
  end)
end
