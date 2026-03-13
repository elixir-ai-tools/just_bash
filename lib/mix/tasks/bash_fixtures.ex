defmodule Mix.Tasks.BashFixtures do
  @moduledoc """
  Generates expected bash outputs for fixture-based comparison tests.

  Reads JSON test case files from `test/fixtures/bash_cases/*.json`,
  runs each script in an Ubuntu Docker container with real bash,
  and writes expected outputs to `test/fixtures/bash_expected/*.json`.

  Locked fixtures (results with `"locked": true`) are preserved during
  re-recording. Use `--force` to overwrite locked fixtures.

  ## Usage

      # Generate all fixtures
      mix bash_fixtures

      # Generate specific suite(s)
      mix bash_fixtures wc sort arithmetic

      # Rebuild Docker image first
      mix bash_fixtures --rebuild

      # Force overwrite locked fixtures
      mix bash_fixtures --force
  """

  use Mix.Task

  @shortdoc "Generate expected bash outputs via Docker"

  @cases_dir Path.expand("../../../test/fixtures/bash_cases", __DIR__)
  @expected_dir Path.expand("../../../test/fixtures/bash_expected", __DIR__)
  @fixtures_dir Path.expand("../../../test/fixtures", __DIR__)
  @docker_image "just-bash-runner"

  @impl Mix.Task
  def run(args) do
    {opts, suites} = parse_args(args)

    ensure_docker_image(opts[:rebuild])

    case_files = discover_case_files(suites)

    if case_files == [] do
      Mix.shell().info("No case files found in #{@cases_dir}")
      :ok
    else
      File.mkdir_p!(@expected_dir)

      Enum.each(case_files, fn case_file ->
        suite = Path.basename(case_file, ".json")
        Mix.shell().info("Generating: #{suite}")

        expected_file = Path.join(@expected_dir, "#{suite}.json")
        generate_expected(case_file, expected_file, opts[:force])
      end)

      Mix.shell().info("Done. Expected outputs in #{@expected_dir}")
    end
  end

  defp parse_args(args) do
    {opts, suites, _} =
      OptionParser.parse(args, switches: [rebuild: :boolean, force: :boolean])

    {opts, suites}
  end

  defp discover_case_files([]) do
    Path.wildcard(Path.join(@cases_dir, "*.json")) |> Enum.sort()
  end

  defp discover_case_files(suites) do
    Enum.flat_map(suites, fn suite ->
      path = Path.join(@cases_dir, "#{suite}.json")

      if File.exists?(path) do
        [path]
      else
        Mix.shell().error("Case file not found: #{path}")
        []
      end
    end)
  end

  defp ensure_docker_image(rebuild) do
    if rebuild || !docker_image_exists?() do
      Mix.shell().info("Building Docker image: #{@docker_image}")

      {output, status} =
        System.cmd("docker", ["build", "-t", @docker_image, @fixtures_dir],
          stderr_to_stdout: true
        )

      if status != 0 do
        Mix.raise("Docker build failed:\n#{output}")
      end
    end
  end

  defp docker_image_exists? do
    case System.cmd("docker", ["image", "inspect", @docker_image], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp generate_expected(case_file, expected_file, force) do
    # Load existing locked fixtures
    locked_by_name = load_locked_fixtures(expected_file, force)

    # Mount the cases file directly into the container and redirect to runner
    {output, status} =
      System.cmd(
        "docker",
        [
          "run",
          "--rm",
          "--network=none",
          "-v",
          "#{@fixtures_dir}/runner.sh:/work/runner.sh:ro",
          "-v",
          "#{Path.expand(case_file)}:/work/cases.json:ro",
          @docker_image,
          "-c",
          "/work/runner.sh < /work/cases.json"
        ],
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.shell().error(
        "Runner failed for #{Path.basename(case_file)} (exit #{status}):\n#{output}"
      )
    else
      decoded = Jason.decode!(output)
      results = merge_locked_results(decoded["results"], locked_by_name)
      merged = Map.put(decoded, "results", results)
      pretty = Jason.encode!(merged, pretty: true)
      File.write!(expected_file, pretty <> "\n")
    end
  end

  defp load_locked_fixtures(expected_file, force) do
    if force || !File.exists?(expected_file) do
      %{}
    else
      expected_file
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("results", [])
      |> Enum.filter(fn r -> r["locked"] == true end)
      |> Enum.into(%{}, fn r -> {r["content_hash"], r} end)
    end
  end

  defp merge_locked_results(new_results, locked_by_hash) when locked_by_hash == %{} do
    new_results
  end

  defp merge_locked_results(new_results, locked_by_hash) do
    Enum.map(new_results, fn result ->
      case Map.get(locked_by_hash, result["content_hash"]) do
        nil ->
          result

        locked ->
          Mix.shell().info("  Keeping locked: #{result["name"]}")
          locked
      end
    end)
  end
end
