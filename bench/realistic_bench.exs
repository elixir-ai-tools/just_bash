# Realistic benchmarks - closer to real-world usage
#
# Run with: mix run bench/realistic_bench.exs

alias JustBash

IO.puts("Setting up realistic benchmarks...\n")

# Setup: create bash with some files
setup_files = %{
  "/data/users.json" =>
    Jason.encode!([
      %{id: 1, name: "Alice", email: "alice@example.com", active: true},
      %{id: 2, name: "Bob", email: "bob@example.com", active: false},
      %{id: 3, name: "Carol", email: "carol@example.com", active: true},
      %{id: 4, name: "Dave", email: "dave@example.com", active: true},
      %{id: 5, name: "Eve", email: "eve@example.com", active: false}
    ]),
  "/data/config.txt" => """
  # Application config
  APP_NAME=myapp
  APP_ENV=production
  DEBUG=false
  MAX_CONNECTIONS=100
  TIMEOUT=30
  """,
  "/data/log.txt" =>
    Enum.map_join(1..100, "\n", fn i ->
      level = Enum.random(["INFO", "WARN", "ERROR", "DEBUG"])
      "[#{level}] 2024-01-#{String.pad_leading("#{rem(i, 28) + 1}", 2, "0")} Message #{i}"
    end),
  "/data/numbers.txt" => Enum.map_join(1..50, "\n", &to_string/1)
}

bash = JustBash.new(files: setup_files)

# Pre-build all commands with single quotes to avoid Elixir string issues
cmd_jq_filter = ~S{cat /data/users.json | jq '.[] | select(.active == true) | .name'}
cmd_jq_extract = ~S{cat /data/users.json | jq -r '.[].email'}
cmd_grep = "grep ERROR /data/log.txt"
cmd_grep_wc = "grep ERROR /data/log.txt | wc -l"
cmd_sed = ~S{sed 's/DEBUG=false/DEBUG=true/' /data/config.txt}
cmd_wc = "wc -l /data/numbers.txt"
cmd_head_tail = "head -20 /data/log.txt | tail -10"
cmd_sort_uniq = "cat /data/numbers.txt /data/numbers.txt | sort -n | uniq"

cmd_transform = ~S"""
cat /data/config.txt | grep -v '^#' | grep -v '^$' > /tmp/clean_config.txt
wc -l /tmp/clean_config.txt
"""

cmd_function = ~S"""
greet() {
  echo "Hello, $1!"
}
greet Alice
greet Bob
greet Carol
"""

cmd_case = ~S"""
for level in INFO WARN ERROR DEBUG; do
  case $level in
    ERROR) echo "$level: CRITICAL" ;;
    WARN)  echo "$level: attention needed" ;;
    *)     echo "$level: normal" ;;
  esac
done
"""

cmd_nested = ~S"""
for i in 1 2 3 4 5; do
  for j in a b c d e; do
    echo "$i$j"
  done
done
"""

cmd_array = ~S"""
arr=(one two three four five)
for item in "${arr[@]}"; do
  echo "Item: $item"
done
"""

cmd_process_json = ~S"""
count=0
for email in $(cat /data/users.json | jq -r '.[].email'); do
  echo "Processing: $email"
  count=$((count + 1))
done
echo "Total: $count users"
"""

Benchee.run(
  %{
    "jq: filter active users" => fn -> JustBash.exec(bash, cmd_jq_filter) end,
    "jq: extract emails" => fn -> JustBash.exec(bash, cmd_jq_extract) end,
    "grep: find errors" => fn -> JustBash.exec(bash, cmd_grep) end,
    "grep | wc: count errors" => fn -> JustBash.exec(bash, cmd_grep_wc) end,
    "sed: modify config" => fn -> JustBash.exec(bash, cmd_sed) end,
    "wc: count lines" => fn -> JustBash.exec(bash, cmd_wc) end,
    "head | tail: lines 10-20" => fn -> JustBash.exec(bash, cmd_head_tail) end,
    "sort | uniq: deduplicate" => fn -> JustBash.exec(bash, cmd_sort_uniq) end,
    "read + transform + write" => fn -> JustBash.exec(bash, cmd_transform) end,
    "function: define and call" => fn -> JustBash.exec(bash, cmd_function) end,
    "case statement" => fn -> JustBash.exec(bash, cmd_case) end,
    "nested loops (5x5)" => fn -> JustBash.exec(bash, cmd_nested) end,
    "array: populate and iterate" => fn -> JustBash.exec(bash, cmd_array) end,
    "script: process JSON users" => fn -> JustBash.exec(bash, cmd_process_json) end
  },
  warmup: 1,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)
