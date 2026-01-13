# Script comparison runner
# Usage: mix run test_scripts/run_comparison.exs [script_pattern]

defmodule ScriptComparison do
  @scripts_dir "test_scripts"

  def run(pattern \\ "*.sh") do
    scripts = Path.wildcard(Path.join(@scripts_dir, pattern)) |> Enum.sort()

    if scripts == [] do
      IO.puts("No scripts found matching pattern: #{pattern}")
      System.halt(1)
    end

    IO.puts("Running #{length(scripts)} test script(s)...\n")
    IO.puts(String.duplicate("=", 70))

    results = Enum.map(scripts, &compare_script/1)

    IO.puts(String.duplicate("=", 70))
    print_summary(results)
  end

  defp compare_script(script_path) do
    script_name = Path.basename(script_path)
    IO.puts("\nScript: #{script_name}")
    IO.puts(String.duplicate("-", 50))

    script_content = File.read!(script_path)

    # Run with real bash
    bash_result = run_bash(script_path)

    # Run with JustBash
    just_bash_result = run_just_bash(script_content)

    # Compare results (focus on stdout for deterministic comparison)
    stdout_match = bash_result.stdout == just_bash_result.stdout
    exit_match = bash_result.exit_code == just_bash_result.exit_code

    all_match = stdout_match and exit_match

    if all_match do
      IO.puts("  Status: PASS")
    else
      IO.puts("  Status: FAIL")

      unless stdout_match do
        IO.puts("\n  STDOUT mismatch:")
        show_diff(bash_result.stdout, just_bash_result.stdout)
      end

      unless exit_match do
        IO.puts(
          "\n  Exit code: bash=#{bash_result.exit_code}, just_bash=#{just_bash_result.exit_code}"
        )
      end
    end

    %{
      script: script_name,
      passed: all_match,
      stdout_match: stdout_match,
      exit_match: exit_match
    }
  end

  defp run_bash(script_path) do
    {stdout, exit_code} = System.cmd("bash", [script_path], stderr_to_stdout: false)
    %{stdout: stdout, exit_code: exit_code}
  rescue
    _ -> %{stdout: "", exit_code: 1}
  end

  defp run_just_bash(script) do
    # Clean up any database files that might interfere with sqlite tests
    # Real bash creates these on disk, but JustBash uses in-memory databases
    cleanup_test_files()

    bash = JustBash.new()
    {result, _bash} = JustBash.exec(bash, script)
    %{stdout: result.stdout, exit_code: result.exit_code}
  end

  defp cleanup_test_files do
    # Remove sqlite database files created by real bash
    # These are created in the current working directory
    ~w[db1 db2 testdb]
    |> Enum.each(&File.rm/1)
  end

  defp show_diff(bash_out, jb_out) do
    bash_lines = String.split(bash_out, "\n")
    jb_lines = String.split(jb_out, "\n")

    # Find first difference
    diff_info = find_first_diff(bash_lines, jb_lines, 0)

    case diff_info do
      {:diff, idx, bash_line, jb_line} ->
        IO.puts("    First difference at line #{idx + 1}:")
        IO.puts("    Bash:     #{inspect(bash_line)}")
        IO.puts("    JustBash: #{inspect(jb_line)}")

        # Show context
        if idx > 0 do
          IO.puts("    (previous line: #{inspect(Enum.at(bash_lines, idx - 1))})")
        end

      {:length, bash_len, jb_len} ->
        IO.puts("    Output length differs: bash=#{bash_len} lines, just_bash=#{jb_len} lines")

        if bash_len > jb_len do
          IO.puts("    Bash has extra line: #{inspect(Enum.at(bash_lines, jb_len))}")
        else
          IO.puts("    JustBash has extra line: #{inspect(Enum.at(jb_lines, bash_len))}")
        end
    end
  end

  defp find_first_diff([], [], _idx), do: nil
  defp find_first_diff([], jb, idx), do: {:length, idx, idx + length(jb)}
  defp find_first_diff(bash, [], idx), do: {:length, idx + length(bash), idx}
  defp find_first_diff([h | t1], [h | t2], idx), do: find_first_diff(t1, t2, idx + 1)
  defp find_first_diff([h1 | _], [h2 | _], idx), do: {:diff, idx, h1, h2}

  defp print_summary(results) do
    total = length(results)
    passed = Enum.count(results, & &1.passed)
    failed = total - passed

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("SUMMARY")
    IO.puts(String.duplicate("=", 70))
    IO.puts("  Total:  #{total}")
    IO.puts("  Passed: #{passed}")
    IO.puts("  Failed: #{failed}")

    if failed > 0 do
      IO.puts("\nFailed scripts:")

      results
      |> Enum.filter(&(not &1.passed))
      |> Enum.each(fn r ->
        issues = []
        issues = if not r.stdout_match, do: ["stdout" | issues], else: issues
        issues = if not r.exit_match, do: ["exit" | issues], else: issues
        IO.puts("  - #{r.script}: #{Enum.join(issues, ", ")}")
      end)

      System.halt(1)
    else
      IO.puts("\nAll tests passed!")
    end
  end
end

# Run with optional pattern argument
pattern =
  case System.argv() do
    [p] -> p
    _ -> "*.sh"
  end

ScriptComparison.run(pattern)
