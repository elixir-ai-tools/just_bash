# Profiling benchmarks - isolate specific bottlenecks
#
# Run with: mix run bench/profile_bench.exs

alias JustBash

IO.puts("=== Profiling Benchmarks ===\n")

bash =
  JustBash.new(
    files: %{
      "/data/small.txt" => Enum.map_join(1..10, "\n", &"line #{&1}"),
      "/data/medium.txt" => Enum.map_join(1..100, "\n", &"line #{&1} with some content"),
      "/data/large.txt" => Enum.map_join(1..500, "\n", &"line #{&1} ERROR warning debug info")
    }
  )

IO.puts("--- 1. While vs For Loop Overhead ---\n")

Benchee.run(
  %{
    "for: 10 iter (static list)" => fn ->
      JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do :; done")
    end,
    "for: 10 iter (seq)" => fn ->
      JustBash.exec(bash, "for i in $(seq 1 10); do :; done")
    end,
    "while: 10 iter" => fn ->
      JustBash.exec(bash, ~S"""
      i=0
      while [ $i -lt 10 ]; do
        i=$((i + 1))
      done
      """)
    end,
    "while: 10 iter (no arithmetic)" => fn ->
      JustBash.exec(bash, ~S"""
      i=0
      while [ $i -lt 10 ]; do
        : $((i += 1))
      done
      """)
    end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

IO.puts("\n--- 2. Condition Evaluation Cost ---\n")

Benchee.run(
  %{
    "[ test ] (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      for i in 1 2 3 4 5 6 7 8 9 10; do
        [ 1 -lt 2 ]
      done
      """)
    end,
    "[[ test ]] (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ 1 -lt 2 ]]
      done
      """)
    end,
    "true command (10x)" => fn ->
      JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do true; done")
    end,
    "no-op : (10x)" => fn ->
      JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do :; done")
    end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

IO.puts("\n--- 3. Grep Performance ---\n")

Benchee.run(
  %{
    "grep literal (10 lines)" => fn ->
      JustBash.exec(bash, "grep line /data/small.txt")
    end,
    "grep literal (100 lines)" => fn ->
      JustBash.exec(bash, "grep line /data/medium.txt")
    end,
    "grep literal (500 lines)" => fn ->
      JustBash.exec(bash, "grep line /data/large.txt")
    end,
    "grep regex (100 lines)" => fn ->
      JustBash.exec(bash, "grep -E 'line [0-9]+' /data/medium.txt")
    end,
    "grep regex (500 lines)" => fn ->
      JustBash.exec(bash, "grep -E 'line [0-9]+' /data/large.txt")
    end,
    "grep -c count (500 lines)" => fn ->
      JustBash.exec(bash, "grep -c ERROR /data/large.txt")
    end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

IO.puts("\n--- 4. Argument Expansion Cost ---\n")

# Pre-build arg strings
args_10 = Enum.map_join(1..10, " ", &"arg#{&1}")
args_50 = Enum.map_join(1..50, " ", &"arg#{&1}")
args_100 = Enum.map_join(1..100, " ", &"arg#{&1}")

Benchee.run(
  %{
    "echo 10 args" => fn ->
      JustBash.exec(bash, "echo #{args_10}")
    end,
    "echo 50 args" => fn ->
      JustBash.exec(bash, "echo #{args_50}")
    end,
    "echo 100 args" => fn ->
      JustBash.exec(bash, "echo #{args_100}")
    end,
    "printf 10 args" => fn ->
      JustBash.exec(bash, "printf '%s ' #{args_10}")
    end,
    "printf 50 args" => fn ->
      JustBash.exec(bash, "printf '%s ' #{args_50}")
    end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

IO.puts("\n--- 5. Variable Expansion Cost ---\n")

Benchee.run(
  %{
    "simple $VAR (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      X=hello
      for i in 1 2 3 4 5 6 7 8 9 10; do echo $X > /dev/null; done
      """)
    end,
    "${VAR} braces (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      X=hello
      for i in 1 2 3 4 5 6 7 8 9 10; do echo ${X} > /dev/null; done
      """)
    end,
    "${VAR:-default} (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      for i in 1 2 3 4 5 6 7 8 9 10; do echo ${UNSET:-default} > /dev/null; done
      """)
    end,
    "${#VAR} length (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      X=hello
      for i in 1 2 3 4 5 6 7 8 9 10; do echo ${#X} > /dev/null; done
      """)
    end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

IO.puts("\n--- 6. Arithmetic Cost ---\n")

Benchee.run(
  %{
    "$(( )) expansion (10x)" => fn ->
      JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do echo $((1+2)) > /dev/null; done")
    end,
    "(( )) command (10x)" => fn ->
      JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do ((x=1+2)); done")
    end,
    "i=$((i+1)) (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      i=0
      for j in 1 2 3 4 5 6 7 8 9 10; do i=$((i+1)); done
      """)
    end,
    "((i++)) (10x)" => fn ->
      JustBash.exec(bash, ~S"""
      i=0
      for j in 1 2 3 4 5 6 7 8 9 10; do ((i++)); done
      """)
    end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

IO.puts("\n--- 7. Parse vs Execute ---\n")

# Test if parsing is the bottleneck
simple_cmd = "echo hello"

complex_cmd = ~S"""
for i in 1 2 3; do
  if [ $i -eq 2 ]; then
    echo "two"
  else
    echo $i
  fi
done
"""

Benchee.run(
  %{
    "parse only (simple)" => fn ->
      JustBash.parse(simple_cmd)
    end,
    "parse + exec (simple)" => fn ->
      JustBash.exec(bash, simple_cmd)
    end,
    "parse only (complex)" => fn ->
      JustBash.parse(complex_cmd)
    end,
    "parse + exec (complex)" => fn ->
      JustBash.exec(bash, complex_cmd)
    end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)
