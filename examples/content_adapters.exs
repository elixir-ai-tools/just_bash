# Example demonstrating content adapter pattern in JustBash
# Run with: mix run examples/content_adapters.exs

alias JustBash.Fs.Content.FunctionContent

IO.puts("=== Content Adapter Examples ===\n")

# Example 1: Function-backed file
IO.puts("1. Function-backed file (dynamic timestamp)")

bash =
  JustBash.new(files: %{
    "/timestamp.txt" => fn -> "Current time: #{DateTime.utc_now()}" end
  })

{result, _bash} = JustBash.exec(bash, "cat /timestamp.txt")
IO.puts("First read:  #{String.trim(result.stdout)}")

Process.sleep(100)

{result, _bash} = JustBash.exec(bash, "cat /timestamp.txt")
IO.puts("Second read: #{String.trim(result.stdout)}")
IO.puts("(Note: timestamps differ because function is called on each read)\n")

# Example 2: MFA tuple for serializable functions
IO.puts("2. MFA tuple (serialization-friendly)")

bash =
  JustBash.new(files: %{
    "/upper.txt" => FunctionContent.new({String, :upcase, ["hello world"]})
  })

{result, _bash} = JustBash.exec(bash, "cat /upper.txt")
IO.puts("Output: #{String.trim(result.stdout)}\n")

# Example 3: Materialization for caching
IO.puts("3. Materialization (cache function results)")

call_count = :counters.new(1, [])

bash =
  JustBash.new(files: %{
    "/counter.txt" =>
      fn ->
        :counters.add(call_count, 1, 1)
        "Function called #{:counters.get(call_count, 1)} time(s)"
      end
  })

{result, bash} = JustBash.exec(bash, "cat /counter.txt")
IO.puts("Before materialize: #{String.trim(result.stdout)}")

{result, bash} = JustBash.exec(bash, "cat /counter.txt")
IO.puts("Before materialize: #{String.trim(result.stdout)}")

# Materialize all lazy content
{:ok, bash} = JustBash.materialize_files(bash)

{result, bash} = JustBash.exec(bash, "cat /counter.txt")
IO.puts("After materialize:  #{String.trim(result.stdout)}")

{result, _bash} = JustBash.exec(bash, "cat /counter.txt")
IO.puts("After materialize:  #{String.trim(result.stdout)}")
IO.puts("(Note: cached value used after materialization)\n")

# Example 4: Mixing static and dynamic content
IO.puts("4. Mixed content types")

bash =
  JustBash.new(files: %{
    "/static.txt" => "Static content",
    "/dynamic.txt" => fn -> "Dynamic: #{System.system_time(:second)}" end,
    "/computed.txt" => FunctionContent.new({Enum, :join, [["a", "b", "c"], "-"]})
  })

{result, bash} = JustBash.exec(bash, "cat /static.txt")
IO.puts("Static:   #{String.trim(result.stdout)}")

{result, bash} = JustBash.exec(bash, "cat /dynamic.txt")
IO.puts("Dynamic:  #{String.trim(result.stdout)}")

{result, _bash} = JustBash.exec(bash, "cat /computed.txt")
IO.puts("Computed: #{String.trim(result.stdout)}\n")

# Example 5: Piping and command composition
IO.puts("5. Command composition with function-backed files")

bash =
  JustBash.new(files: %{
    "/data.txt" => fn -> "apple\nbanana\ncherry\napricot\navocado\n" end
  })

{result, _bash} = JustBash.exec(bash, "cat /data.txt | grep a | wc -l")
IO.puts("Lines containing 'a': #{String.trim(result.stdout)}\n")

# Example 6: Redirections (function-backed file becomes binary after write)
IO.puts("6. Redirections (lazy content becomes eager after write)")

bash =
  JustBash.new(files: %{
    "/log.txt" => fn -> "Initial log entry" end
  })

{result, bash} = JustBash.exec(bash, "cat /log.txt")
IO.puts("Before write: #{String.trim(result.stdout)}")

{_result, bash} = JustBash.exec(bash, "echo 'New log entry' > /log.txt")

{result, _bash} = JustBash.exec(bash, "cat /log.txt")
IO.puts("After write:  #{String.trim(result.stdout)}")
IO.puts("(Note: content is now static binary)\n")

IO.puts("=== All examples completed ===")
