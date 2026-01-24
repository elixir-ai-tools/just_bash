# Stress benchmarks - push the limits
#
# Run with: mix run bench/stress_bench.exs

alias JustBash

IO.puts("Setting up stress benchmarks...\n")

# Generate large test data
large_json =
  Jason.encode!(
    Enum.map(1..100, fn i ->
      %{
        id: i,
        name: "User #{i}",
        email: "user#{i}@example.com",
        tags: ["tag#{rem(i, 5)}", "tag#{rem(i, 3)}"],
        score: :rand.uniform(100)
      }
    end)
  )

large_log =
  Enum.map_join(1..500, "\n", fn i ->
    level = Enum.at(["INFO", "WARN", "ERROR", "DEBUG"], rem(i, 4))

    "[#{level}] 2024-01-#{String.pad_leading("#{rem(i, 28) + 1}", 2, "0")} Request #{i} processed in #{:rand.uniform(100)}ms"
  end)

many_files =
  Map.new(1..20, fn i ->
    {"/data/file#{i}.txt", "Content of file #{i}\nLine 2\nLine 3\n"}
  end)

bash =
  JustBash.new(
    files:
      Map.merge(many_files, %{
        "/data/large.json" => large_json,
        "/data/large.log" => large_log,
        "/data/words.txt" => Enum.map_join(1..200, "\n", fn i -> "word#{rem(i, 50)}" end)
      })
  )

# Build command strings
many_args = Enum.map_join(1..50, " ", &"arg#{&1}")
long_pipeline = Enum.map_join(1..10, " | ", fn _ -> "cat" end)

# Commands with special characters - use ~S{} delimiter
cmd_jq_filter = ~S{cat /data/large.json | jq '[.[] | select(.score > 50)]'}
cmd_jq_group = "cat /data/large.json | jq length"

cmd_loop_files = ~S"""
total=0
for f in /data/file*.txt; do
  lines=$(wc -l < "$f")
  total=$((total + lines))
done
echo "Total lines: $total"
"""

cmd_nested = ~S"""
for i in $(seq 1 10); do
  for j in $(seq 1 10); do
    echo "$i,$j" > /dev/null
  done
done
"""

cmd_many_vars = ~S"""
A=1 B=2 C=3 D=4 E=5
for i in $(seq 1 20); do
  echo "$A $B $C $D $E $A $B $C $D $E" > /dev/null
done
"""

Benchee.run(
  %{
    # Many arguments (tests arg expansion performance)
    "echo with 50 args" => fn ->
      JustBash.exec(bash, "echo #{many_args}")
    end,

    # Long pipeline (tests pipeline execution)
    "10-stage pipeline" => fn ->
      JustBash.exec(bash, "echo test | #{long_pipeline}")
    end,

    # Large JSON processing
    "jq: filter 100 records" => fn ->
      JustBash.exec(bash, cmd_jq_filter)
    end,

    # Large file grep
    "grep: search 500-line log" => fn ->
      JustBash.exec(bash, "grep ERROR /data/large.log")
    end,

    # Many iterations
    "for loop: 100 iterations" => fn ->
      JustBash.exec(bash, "for i in $(seq 1 100); do echo $i > /dev/null; done")
    end,

    # Sort large file
    "sort: 200 lines" => fn ->
      JustBash.exec(bash, "sort /data/words.txt | uniq -c | sort -rn")
    end,

    # Process many files
    "loop over 20 files" => fn ->
      JustBash.exec(bash, cmd_loop_files)
    end,

    # Complex jq transformation
    "jq: group and aggregate" => fn ->
      JustBash.exec(bash, cmd_jq_group)
    end,

    # Deeply nested structure
    "nested loops (10x10)" => fn ->
      JustBash.exec(bash, cmd_nested)
    end,

    # Many variable expansions
    "100 variable expansions" => fn ->
      JustBash.exec(bash, cmd_many_vars)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)
