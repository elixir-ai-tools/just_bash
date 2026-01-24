# Simple benchmarks - basic operations
#
# Run with: mix run bench/simple_bench.exs

alias JustBash

IO.puts("Setting up benchmarks...\n")

# Pre-create bash instances to isolate setup from benchmark
bash = JustBash.new()

Benchee.run(
  %{
    # Minimal: just parse and execute simplest command
    "echo hello" => fn ->
      JustBash.exec(bash, "echo hello")
    end,

    # Variable expansion
    "variable expansion" => fn ->
      JustBash.exec(bash, ~S[X=world; echo "hello $X"])
    end,

    # Multiple commands (semicolon)
    "3 sequential commands" => fn ->
      JustBash.exec(bash, "echo a; echo b; echo c")
    end,

    # Simple pipeline
    "pipe: echo | cat" => fn ->
      JustBash.exec(bash, "echo hello | cat")
    end,

    # Longer pipeline (tests exit code accumulation)
    "pipe: 5 stages" => fn ->
      JustBash.exec(bash, "echo hello | cat | cat | cat | cat")
    end,

    # Conditionals
    "if/then/else" => fn ->
      JustBash.exec(bash, "if true; then echo yes; else echo no; fi")
    end,

    # Small for loop
    "for loop (10 iterations)" => fn ->
      JustBash.exec(bash, "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i; done")
    end,

    # While loop with counter
    "while loop (10 iterations)" => fn ->
      JustBash.exec(bash, ~S"""
      i=0
      while [ $i -lt 10 ]; do
        echo $i
        i=$((i + 1))
      done
      """)
    end,

    # Command substitution
    "command substitution" => fn ->
      JustBash.exec(bash, ~S[echo "Today is $(date +%Y)"])
    end,

    # Arithmetic
    "arithmetic expansion" => fn ->
      JustBash.exec(bash, "echo $((1 + 2 * 3))")
    end
  },
  warmup: 1,
  time: 3,
  memory_time: 1,
  print: [configuration: false]
)
