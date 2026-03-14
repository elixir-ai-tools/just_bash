defmodule Mix.Tasks.JustBash.Eval do
  @shortdoc "Run JustBash agent evals"
  @moduledoc """
  Runs the JustBash agent eval suite.

  ## Usage

      mix just_bash.eval                       # Run all evals
      mix just_bash.eval --task jq_transform   # Run a specific eval
      mix just_bash.eval --retries 3           # Retry failing tasks up to 3 times
      mix just_bash.eval --concurrency 8       # Run 8 tasks concurrently
      mix just_bash.eval --no-persist          # Skip writing results to JSONL
      mix just_bash.eval --verbose             # Verbose output (default: true)

  Results are written to eval_results/results.jsonl by default.
  Requires ANTHROPIC_API_KEY in environment or config.
  """

  use Mix.Task

  alias JustBash.Eval.Runner

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          task: :string,
          verbose: :boolean,
          retries: :integer,
          concurrency: :integer,
          persist: :boolean
        ]
      )

    verbose = Keyword.get(opts, :verbose, true)

    runner_opts =
      [verbose: verbose]
      |> maybe_put(:retries, Keyword.get(opts, :retries))
      |> maybe_put(:concurrency, Keyword.get(opts, :concurrency))
      |> maybe_put(:persist, Keyword.get(opts, :persist))

    results =
      case Keyword.get(opts, :task) do
        nil ->
          Runner.run_all(runner_opts)

        name ->
          [Runner.run_by_name(name, runner_opts)]
      end

    Runner.print_summary(results)

    if Enum.all?(results, & &1.passed) do
      :ok
    else
      Mix.raise("Some evals failed")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
