defmodule JustBash.Eval.Runner do
  @moduledoc """
  Runs eval tasks with retry, concurrency, and result persistence.

  Features:
  - Per-task retry (configurable, default 1 attempt)
  - Concurrent execution via Task.async_stream
  - JSONL result persistence to eval_results/
  - Token usage and cost tracking
  """

  alias JustBash.Eval.{Agent, Tasks, Validator}
  alias JustBash.FS

  @type validator_result :: Validator.validator_result()

  @type task_result :: %{
          name: String.t(),
          passed: boolean(),
          validators: [validator_result()],
          turns: non_neg_integer(),
          error: String.t() | nil,
          time_ms: non_neg_integer(),
          usage: map(),
          attempt: pos_integer()
        }

  @results_dir "eval_results"

  # Sonnet pricing per 1M tokens
  @input_cost_per_million 1.0
  @output_cost_per_million 5.0

  @doc """
  Run all eval tasks and return results.

  Options:
    - `:tasks` — list of tasks (default: all)
    - `:retries` — max attempts per task (default: 1)
    - `:concurrency` — max concurrent tasks (default: 4)
    - `:verbose` — print progress (default: false)
    - `:persist` — write results to JSONL (default: true)
  """
  @spec run_all(keyword()) :: [task_result()]
  def run_all(opts \\ []) do
    tasks = Keyword.get(opts, :tasks, Tasks.all())
    concurrency = Keyword.get(opts, :concurrency, 4)
    persist? = Keyword.get(opts, :persist, true)

    results =
      tasks
      |> Task.async_stream(
        fn task -> run_task(task, opts) end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, result} -> result end)

    if persist?, do: persist_results(results)

    results
  end

  @doc """
  Run a single eval task by name.
  """
  @spec run_by_name(String.t(), keyword()) :: task_result()
  def run_by_name(name, opts \\ []) do
    persist? = Keyword.get(opts, :persist, true)

    result =
      case Enum.find(Tasks.all(), &(&1.name == name)) do
        nil ->
          %{
            name: name,
            passed: false,
            validators: [],
            turns: 0,
            error: "Task not found",
            time_ms: 0,
            usage: %{input_tokens: 0, output_tokens: 0},
            attempt: 0
          }

        task ->
          run_task(task, opts)
      end

    if persist?, do: persist_results([result])

    result
  end

  @doc """
  Run a single task with retry support.
  """
  @spec run_task(Tasks.task(), keyword()) :: task_result()
  def run_task(task, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    retries = Keyword.get(opts, :retries, 1)

    if verbose, do: IO.puts("\n--- Running: #{task.name} ---")

    run_with_retry(task, opts, 1, retries, nil)
  end

  defp run_with_retry(_task, _opts, attempt, max_attempts, last_result)
       when attempt > max_attempts do
    last_result
  end

  defp run_with_retry(task, opts, attempt, max_attempts, _last_result) do
    verbose = Keyword.get(opts, :verbose, false)

    if attempt > 1 and verbose,
      do: IO.puts("  retry #{attempt}/#{max_attempts} for #{task.name}")

    result = execute_task(task, opts, attempt)

    if result.passed do
      result
    else
      run_with_retry(task, opts, attempt + 1, max_attempts, result)
    end
  end

  defp execute_task(task, opts, attempt) do
    verbose = Keyword.get(opts, :verbose, false)
    start = System.monotonic_time(:millisecond)
    commands = Map.get(task, :commands, %{})
    bash = setup_filesystem(task.files, commands)
    agent_opts = Keyword.merge(opts, bash: bash)

    agent_opts =
      if commands != %{} do
        commands_help = build_commands_help(bash, commands)
        Keyword.put(agent_opts, :commands_info, commands_help)
      else
        agent_opts
      end

    try do
      case Agent.run(task.description, agent_opts) do
        {:ok, agent_result} ->
          time_ms = System.monotonic_time(:millisecond) - start
          validator_results = Validator.run_all(task.validators, agent_result)
          all_passed = Enum.all?(validator_results, & &1.passed)

          if verbose,
            do: print_validator_results(task.name, validator_results, agent_result.turns, time_ms)

          %{
            name: task.name,
            passed: all_passed,
            validators: validator_results,
            turns: agent_result.turns,
            error: nil,
            time_ms: time_ms,
            usage: agent_result.usage,
            attempt: attempt
          }

        {:error, reason} ->
          time_ms = System.monotonic_time(:millisecond) - start
          error_msg = inspect(reason)
          if verbose, do: IO.puts("  ERROR: #{error_msg} (#{time_ms}ms)")

          %{
            name: task.name,
            passed: false,
            validators: [],
            turns: 0,
            error: error_msg,
            time_ms: time_ms,
            usage: %{input_tokens: 0, output_tokens: 0},
            attempt: attempt
          }
      end
    rescue
      e ->
        time_ms = System.monotonic_time(:millisecond) - start
        error_msg = "CRASH: #{Exception.message(e)}"
        if verbose, do: IO.puts("  #{error_msg} (#{time_ms}ms)")

        %{
          name: task.name,
          passed: false,
          validators: [],
          turns: 0,
          error: error_msg,
          time_ms: time_ms,
          usage: %{input_tokens: 0, output_tokens: 0},
          attempt: attempt
        }
    end
  end

  @doc """
  Print a summary table of results.
  """
  @spec print_summary([task_result()]) :: :ok
  def print_summary(results) do
    passed = Enum.count(results, & &1.passed)
    total = length(results)
    total_time = results |> Enum.map(& &1.time_ms) |> Enum.sum()

    total_validators = results |> Enum.flat_map(& &1.validators) |> length()
    passed_validators = results |> Enum.flat_map(& &1.validators) |> Enum.count(& &1.passed)

    total_input = results |> Enum.map(&get_in(&1, [:usage, :input_tokens])) |> Enum.sum()
    total_output = results |> Enum.map(&get_in(&1, [:usage, :output_tokens])) |> Enum.sum()

    cost =
      total_input / 1_000_000 * @input_cost_per_million +
        total_output / 1_000_000 * @output_cost_per_million

    IO.puts("\n" <> String.duplicate("=", 70))

    IO.puts(
      "EVAL RESULTS: #{passed}/#{total} tasks passed | " <>
        "#{passed_validators}/#{total_validators} validators passed | #{total_time}ms"
    )

    IO.puts(
      "TOKENS: #{total_input} in + #{total_output} out | " <>
        "COST: $#{Float.round(cost, 3)}"
    )

    IO.puts(String.duplicate("=", 70))

    for r <- results do
      status = if r.passed, do: color("PASS", :green), else: color("FAIL", :red)
      retry_note = if r.attempt > 1, do: " (attempt #{r.attempt})", else: ""
      IO.puts("  #{status}  #{r.name} (#{r.turns} turns, #{r.time_ms}ms#{retry_note})")

      if r.error do
        IO.puts("        #{color(r.error, :red)}")
      end

      for v <- r.validators do
        v_status = if v.passed, do: color("ok", :green), else: color("FAIL", :red)
        line = "        #{v_status} #{v.name}"
        line = if v.error, do: line <> " — #{v.error}", else: line
        IO.puts(line)
      end
    end

    IO.puts(String.duplicate("=", 70))
    :ok
  end

  # --- Result persistence ---

  defp persist_results(results) do
    File.mkdir_p!(@results_dir)

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    commit_sha = get_commit_sha()

    run_record = %{
      timestamp: timestamp,
      commit: commit_sha,
      total_tasks: length(results),
      passed: Enum.count(results, & &1.passed),
      total_time_ms: results |> Enum.map(& &1.time_ms) |> Enum.sum(),
      total_input_tokens: results |> Enum.map(&get_in(&1, [:usage, :input_tokens])) |> Enum.sum(),
      total_output_tokens:
        results |> Enum.map(&get_in(&1, [:usage, :output_tokens])) |> Enum.sum(),
      tasks:
        Enum.map(results, fn r ->
          %{
            name: r.name,
            passed: r.passed,
            turns: r.turns,
            time_ms: r.time_ms,
            attempt: r.attempt,
            input_tokens: get_in(r, [:usage, :input_tokens]),
            output_tokens: get_in(r, [:usage, :output_tokens]),
            error: r.error,
            validators:
              Enum.map(r.validators, fn v ->
                %{name: v.name, passed: v.passed, error: v.error}
              end)
          }
        end)
    }

    path = Path.join(@results_dir, "results.jsonl")
    line = Jason.encode!(run_record) <> "\n"
    File.write!(path, line, [:append])
  end

  defp get_commit_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  # --- Private ---

  defp print_validator_results(_task_name, results, turns, time_ms) do
    all_passed = Enum.all?(results, & &1.passed)
    status = if all_passed, do: "PASS", else: "FAIL"
    IO.puts("  #{status} (#{turns} turns, #{time_ms}ms)")

    for r <- results do
      indicator = if r.passed, do: color("ok", :green), else: color("FAIL", :red)
      line = "    #{indicator} #{r.name}"
      line = if r.error, do: line <> " — #{r.error}", else: line
      IO.puts(line)
    end
  end

  defp build_commands_help(bash, commands) do
    commands
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map_join("\n", fn name ->
      module = Map.get(bash.commands, name)
      {result, _} = module.execute(bash, ["--help"], "")

      if result.exit_code == 0 and result.stdout != "" do
        result.stdout
      else
        "#{name}: custom command (run `#{name} --help` for usage)"
      end
    end)
  end

  defp setup_filesystem(files, commands) do
    bash = JustBash.new(commands: commands)

    fs =
      Enum.reduce(files, bash.fs, fn {path, content}, fs ->
        fs = ensure_parent_dirs(fs, path)
        {:ok, fs} = FS.write_file(fs, path, content)
        fs
      end)

    %{bash | fs: fs}
  end

  defp ensure_parent_dirs(fs, path) do
    path
    |> Path.dirname()
    |> Path.split()
    |> Enum.reduce({"", fs}, fn segment, {current, fs} ->
      dir = Path.join(current, segment)

      case FS.mkdir(fs, dir) do
        {:ok, fs} -> {dir, fs}
        {:error, :eexist} -> {dir, fs}
      end
    end)
    |> elem(1)
  end

  defp color(text, :green), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp color(text, :red), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
end
