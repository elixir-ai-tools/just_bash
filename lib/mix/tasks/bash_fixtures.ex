defmodule Mix.Tasks.BashFixtures do
  @moduledoc """
  Records what real bash does for the fixture comparison corpus.

  Reads case files from `test/fixtures/bash_cases/*.json`, runs each script under
  real bash in a Docker container, and writes the resulting stdout, stderr and
  exit code to `test/fixtures/bash_expected/*.json`. `JustBash.FixtureTest` then
  asserts JustBash produces the same bytes, offline.

  A whole suite is recorded in a single container: startup dominates per-case
  cost, so batching is what keeps recording the corpus tractable.

  Cases and recordings are joined by `content_hash`, a digest of the case inputs
  computed by `JustBash.Fixtures`. Editing a script therefore changes its hash
  and orphans its recording, which `mix bash_fixtures.verify` detects offline —
  no Docker needed on the PR path.

  ## Usage

      # Record all suites
      mix bash_fixtures

      # Record specific suites
      mix bash_fixtures wc sort arithmetic

      # Rebuild the Docker image first
      mix bash_fixtures --rebuild

  ## Related tasks

    * `mix bash_fixtures.verify` — offline integrity check (no Docker)
    * `mix bash_fixtures.rehash` — recompute stored hashes after a script edit
  """

  use Mix.Task

  alias JustBash.Fixtures

  @shortdoc "Record expected bash outputs via Docker"

  @cases_dir Path.expand("../../../test/fixtures/bash_cases", __DIR__)
  @expected_dir Path.expand("../../../test/fixtures/bash_expected", __DIR__)
  @fixtures_dir Path.expand("../../../test/fixtures", __DIR__)
  @docker_image "just-bash-runner"

  @doc false
  def cases_dir, do: @cases_dir

  @doc false
  def expected_dir, do: @expected_dir

  @impl Mix.Task
  def run(args) do
    {opts, suites} = parse_args(args)

    ensure_docker_image(opts[:rebuild])

    case discover_case_files(suites) do
      [] ->
        Mix.shell().info("No case files found in #{@cases_dir}")

      case_files ->
        File.mkdir_p!(@expected_dir)

        case_files
        |> Enum.flat_map(fn case_file ->
          suite = Path.basename(case_file, ".json")
          Mix.shell().info("Recording: #{suite}")
          record_suite(case_file, Path.join(@expected_dir, "#{suite}.json"))
        end)
        |> finish()
    end
  end

  # A suite that failed to record leaves the corpus in a state the test suite
  # cannot detect on its own — the expectation file it would have replaced is
  # still there and still passing. Reporting it on stderr and exiting 0 makes a
  # failed recording look like a successful one to everything downstream.
  defp finish([]), do: Mix.shell().info("Done. Expected outputs in #{@expected_dir}")

  defp finish(failures) do
    Mix.raise("""

    #{length(failures)} suite(s) were not recorded:

    #{Enum.map_join(failures, "\n", &"  - #{&1}")}
    """)
  end

  defp parse_args(args) do
    {opts, suites, _} = OptionParser.parse(args, switches: [rebuild: :boolean])
    {opts, suites}
  end

  @doc false
  @spec discover_case_files([String.t()]) :: [String.t()]
  def discover_case_files([]) do
    @cases_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
  end

  def discover_case_files(suites) do
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

  @doc false
  @spec read_json!(String.t()) :: map()
  def read_json!(path), do: path |> File.read!() |> Jason.decode!()

  @doc false
  @spec write_json!(String.t(), map()) :: :ok
  def write_json!(path, data), do: File.write!(path, Jason.encode!(data, pretty: true) <> "\n")

  defp ensure_docker_image(rebuild) do
    if rebuild || !docker_image_exists?() do
      Mix.shell().info("Building Docker image: #{@docker_image}")

      {output, status} =
        System.cmd("docker", ["build", "-t", @docker_image, @fixtures_dir],
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("Docker build failed:\n#{output}")
    end
  end

  defp docker_image_exists? do
    case System.cmd("docker", ["image", "inspect", @docker_image], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp record_suite(case_file, expected_file) do
    out_dir = Path.join(System.tmp_dir!(), "just_bash_fixtures_#{unique_suffix()}")
    File.mkdir_p!(out_dir)

    try do
      with {:ok, recorded} <- run_container(case_file, out_dir),
           :ok <- verify_recorded(case_file, recorded) do
        write_json!(expected_file, recorded)
        []
      else
        {:error, message} ->
          Mix.shell().error("#{Path.basename(case_file)}: #{message}")
          [Path.basename(case_file, ".json")]
      end
    after
      File.rm_rf!(out_dir)
    end
  end

  # The runner writes its payload to a mounted file rather than stdout. Docker
  # itself writes to stderr (image platform mismatches, pull progress), and
  # folding that into the payload would corrupt the JSON — silently, since a
  # truncated parse fails far from its cause.
  defp run_container(case_file, out_dir) do
    args = [
      "run",
      "--rm",
      "--network=none",
      "-v",
      "#{@fixtures_dir}/runner.sh:/work/runner.sh:ro",
      "-v",
      "#{Path.expand(case_file)}:/work/cases.json:ro",
      "-v",
      "#{out_dir}:/out",
      @docker_image,
      "-c",
      "/work/runner.sh < /work/cases.json > /out/result.json"
    ]

    {diagnostics, status} = System.cmd("docker", args, stderr_to_stdout: true)
    result_path = Path.join(out_dir, "result.json")

    cond do
      status != 0 -> {:error, "runner exited #{status}:\n#{diagnostics}"}
      not File.exists?(result_path) -> {:error, "runner wrote no output:\n#{diagnostics}"}
      true -> {:ok, read_json!(result_path)}
    end
  end

  # A recording is only usable if every live case can find it. Checking here
  # means a hash mismatch surfaces at record time, against the container we just
  # ran, rather than as a puzzling compile error in the test suite later — and
  # the unusable recording is not written, because a corpus that fails to record
  # and a corpus that recorded cleanly must not look the same afterwards.
  defp verify_recorded(case_file, recorded) do
    cases = case_file |> read_json!() |> Map.fetch!("cases")

    case Fixtures.validate(cases, Map.get(recorded, "results", [])) do
      [] ->
        :ok

      problems ->
        {:error,
         "recorded output does not cover every case, so it was not written:\n" <>
           Enum.map_join(problems, "\n", &"  - #{Fixtures.describe(&1)}") <>
           "\n  Run `mix bash_fixtures.rehash #{Path.basename(case_file, ".json")}` first."}
    end
  end

  defp unique_suffix, do: Integer.to_string(System.unique_integer([:positive]))
end
