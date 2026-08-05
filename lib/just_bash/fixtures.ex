defmodule JustBash.Fixtures do
  @moduledoc """
  Content-addressing and integrity rules for the bash comparison fixture corpus.

  Fixture cases live in `test/fixtures/bash_cases/<suite>.json`; the outputs real
  bash produced for them live in `test/fixtures/bash_expected/<suite>.json`. The
  two files are joined by `content_hash` — a digest of the case's *inputs*, so a
  recording is addressed by the script that produced it rather than by its name.

  That join only means anything if the hash is recomputed from the inputs on
  every read. A stored hash that is never re-derived degrades into an opaque
  label: edit the script, leave the hash, and the case keeps passing while
  asserting against output recorded for a different script. `content_hash/2` is
  the single definition both the recorder (`mix bash_fixtures`) and the test
  (`JustBash.FixtureTest`) call, so the two cannot disagree.

  ## The digest

      content_hash = sha256(canonical(script, files)) |> hex |> first 16 chars

      canonical = ~s({"files":) <> compact_json(files) <> ~s(,"script":) <>
                  compact_json(script) <> ~s(})

  Compact JSON means no insignificant whitespace, and non-ASCII is emitted as
  raw UTF-8 rather than `\\uXXXX` escapes. `files` keys are sorted by path so the
  digest never depends on map iteration order.

  Only the fields that feed the recording — `script` and `files` — are hashed.
  Comparison settings (`name`, `opts.ignore_exit`, `opts.ignore_stderr`) are
  deliberately excluded: renaming a case or widening what it tolerates must not
  invalidate a recording that is still byte-for-byte correct.

  ## Versioning

  `@hash_version` records the current canonicalization. Changing the digest
  invalidates every recorded expectation at once, so it must be a deliberate,
  greppable event rather than an accident: bump this, and re-record the corpus.
  """

  # Bump only alongside a full corpus re-record. See "Versioning" above.
  @hash_version 1

  @hash_chars 16

  @doc "The canonicalization version this module implements."
  @spec hash_version() :: pos_integer()
  def hash_version, do: @hash_version

  @doc """
  Digests a case's inputs into its `content_hash`.

  ## Examples

      iex> JustBash.Fixtures.content_hash("echo 'hello world' | wc")
      "d34a7800e7f5b693"

      iex> JustBash.Fixtures.content_hash("echo hi") ==
      ...>   JustBash.Fixtures.content_hash("echo hi", %{})
      true
  """
  @spec content_hash(String.t(), map()) :: String.t()
  def content_hash(script, files \\ %{}) when is_binary(script) and is_map(files) do
    :crypto.hash(:sha256, canonical(script, files))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_chars)
  end

  @doc """
  Digests a decoded case map, tolerating an absent or null `"files"`.

  Accepts the shape found in `bash_cases/*.json`, so callers that have just
  decoded a suite file need not destructure it first.
  """
  @spec hash_case(map()) :: String.t()
  def hash_case(%{"script" => script} = test_case) do
    content_hash(script, test_case["files"] || %{})
  end

  # A case with no script cannot be hashed, run or recorded. Saying so beats a
  # FunctionClauseError raised from inside `validate/2`, which reads as a bug in
  # the checker rather than a malformed case file.
  def hash_case(test_case) do
    raise ArgumentError,
          "fixture case has no \"script\" key: #{inspect(test_case, limit: 5)}"
  end

  @doc """
  The exact bytes `content_hash/2` digests.

  Exposed for diagnosing a hash mismatch: comparing canonical forms says *which*
  input drifted, where comparing digests only says that something did.
  """
  @spec canonical(String.t(), map()) :: binary()
  def canonical(script, files) when is_binary(script) and is_map(files) do
    IO.iodata_to_binary([
      ~s({"files":),
      encode_files(files),
      ~s(,"script":),
      Jason.encode_to_iodata!(script),
      ~s(})
    ])
  end

  # Emitted by hand rather than via Jason.encode!/1 so key order is sorted by
  # path instead of inheriting map iteration order, which is unspecified.
  defp encode_files(files) do
    inner =
      files
      |> Enum.sort_by(fn {path, _contents} -> path end)
      |> Enum.map_intersperse(",", fn {path, contents} ->
        [Jason.encode_to_iodata!(path), ":", Jason.encode_to_iodata!(contents)]
      end)

    ["{", inner, "}"]
  end

  @typedoc """
  An integrity violation found by `validate/2`.

  * `:stale_hash` — the stored hash is not the digest of the current inputs, so
    the case is joined to a recording made from a different script
  * `:missing_recording` — the case has no recorded expectation
  * `:orphan_recording` — a recording whose hash matches no live case
  * `:hash_collision` — one hash claimed by cases with differing inputs
  """
  @type problem ::
          {:stale_hash, name :: String.t(), stored :: String.t() | nil, computed :: String.t()}
          | {:missing_recording, name :: String.t(), computed :: String.t()}
          | {:orphan_recording, hash :: String.t()}
          | {:hash_collision, hash :: String.t(), names :: [String.t()]}

  @doc """
  Checks a decoded suite's cases against its decoded recordings.

  Pure, so it runs both offline in `mix bash_fixtures.verify` and at compile
  time in the fixture test. Returns `[]` when the suite is sound; problems are
  returned rather than raised so a caller can report every one at once instead
  of one per run.
  """
  @spec validate([map()], [map()]) :: [problem()]
  def validate(cases, results) do
    recorded = MapSet.new(results, & &1["content_hash"])
    live = MapSet.new(cases, &hash_case/1)

    Enum.concat([
      case_problems(cases, recorded),
      collision_problems(cases),
      Enum.map(MapSet.difference(recorded, live), &{:orphan_recording, &1})
    ])
  end

  defp case_problems(cases, recorded) do
    Enum.flat_map(cases, fn test_case ->
      %{"name" => name} = test_case
      computed = hash_case(test_case)

      cond do
        test_case["content_hash"] != computed ->
          [{:stale_hash, name, test_case["content_hash"], computed}]

        not MapSet.member?(recorded, computed) ->
          [{:missing_recording, name, computed}]

        true ->
          []
      end
    end)
  end

  # Two cases may legitimately share a hash when their inputs are byte-identical
  # (the corpus has one such pair, differing only in name). Differing inputs
  # under one hash would mean the recordings silently collapse.
  defp collision_problems(cases) do
    cases
    |> Enum.group_by(&hash_case/1)
    |> Enum.filter(fn {_hash, group} ->
      group |> Enum.uniq_by(&{&1["script"], &1["files"]}) |> length() > 1
    end)
    |> Enum.map(fn {hash, group} -> {:hash_collision, hash, Enum.map(group, & &1["name"])} end)
  end

  @doc """
  Renders a `t:problem/0` as a single actionable line.
  """
  @spec describe(problem()) :: String.t()
  def describe({:stale_hash, name, stored, computed}) do
    "stale hash: #{name}\n" <>
      "    stored:   #{stored || "(none)"}\n" <>
      "    computed: #{computed}\n" <>
      "    The script changed after recording, so this case asserts against\n" <>
      "    output recorded for a different script."
  end

  def describe({:missing_recording, name, computed}) do
    "no recording for: #{name} (#{computed})"
  end

  def describe({:orphan_recording, hash}) do
    "orphan recording, no live case: #{hash}"
  end

  def describe({:hash_collision, hash, names}) do
    "hash #{hash} claimed by cases with differing inputs:\n" <>
      Enum.map_join(names, "\n", &"    - #{&1}")
  end
end
