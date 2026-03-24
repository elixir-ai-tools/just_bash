defmodule JustBash.Security.Policy do
  @moduledoc """
  Central security policy for untrusted-code execution.

  JustBash treats all shell input as untrusted and enforces resource limits
  to prevent runaway code. The policy controls how much work a script is
  allowed to do before execution is halted.

  Most users only need a preset:

      JustBash.new()                    # safe defaults
      JustBash.new(security: :strict)   # tighter limits
      JustBash.new(security: :relaxed)  # heavier workloads

  For fine-tuning, override specific limits on any preset base:

      JustBash.new(security: [max_steps: 50_000])
      JustBash.new(security: [profile: :strict, max_output_bytes: 5_000_000])

  ## User-facing options

  These are the limits you are most likely to tune:

  - `:max_steps`          — total command steps per `exec` call (default: 100,000)
  - `:max_iterations`     — iterations per loop (default: 10,000)
  - `:max_output_bytes`   — combined stdout + stderr bytes (default: 1,000,000)
  - `:max_total_fs_bytes` — total virtual filesystem size (default: 8,000,000)
  - `:max_call_depth`     — shell function recursion depth (default: 1,000)

  All other limits (parsing, expansion, regex, glob, jq, etc.) are tuned
  automatically by the preset and rarely need manual adjustment.
  """

  # -- User-facing keys: the ones we document and encourage tuning ----------
  @public_keys [
    :max_steps,
    :max_iterations,
    :max_output_bytes,
    :max_total_fs_bytes,
    :max_call_depth
  ]

  # -- All defaults (public + internal) -------------------------------------
  @defaults %{
    # User-facing
    max_iterations: 10_000,
    max_call_depth: 1_000,
    max_steps: 100_000,
    max_output_bytes: 1_000_000,
    max_total_fs_bytes: 8_000_000,
    # Internal: execution
    max_exec_depth: 128,
    # Internal: parsing
    max_input_bytes: 64_000,
    max_tokens: 10_000,
    max_ast_nodes: 20_000,
    max_nesting_depth: 64,
    # Internal: expansion
    max_expanded_words: 10_000,
    max_glob_matches: 5_000,
    max_file_walk_entries: 10_000,
    # Internal: regex
    max_regex_pattern_bytes: 4_000,
    max_regex_input_bytes: 64_000,
    # Internal: environment
    max_env_bytes: 128_000,
    max_array_entries: 10_000,
    max_array_bytes: 1_000_000,
    # Internal: filesystem
    max_file_bytes: 1_000_000,
    # Internal: network
    max_http_body_bytes: 1_000_000,
    # Internal: jq
    max_jq_results: 10_000,
    max_jq_depth: 64,
    max_jq_input_bytes: 1_000_000,
    max_jq_input_depth: 128,
    max_jq_work_items: 10_000
  }

  @all_keys Map.keys(@defaults)

  @strict %{
    max_iterations: 2_000,
    max_call_depth: 256,
    max_steps: 20_000,
    max_output_bytes: 250_000,
    max_total_fs_bytes: 2_000_000,
    max_exec_depth: 32,
    max_input_bytes: 16_000,
    max_tokens: 2_000,
    max_ast_nodes: 4_000,
    max_nesting_depth: 24,
    max_expanded_words: 2_000,
    max_http_body_bytes: 250_000,
    max_regex_pattern_bytes: 1_000,
    max_regex_input_bytes: 16_000,
    max_glob_matches: 1_000,
    max_file_walk_entries: 2_000,
    max_env_bytes: 32_000,
    max_array_entries: 2_000,
    max_array_bytes: 250_000,
    max_jq_results: 2_000,
    max_jq_depth: 24,
    max_jq_input_bytes: 250_000,
    max_jq_input_depth: 48,
    max_jq_work_items: 2_000,
    max_file_bytes: 250_000
  }

  @relaxed %{
    max_iterations: 100_000,
    max_call_depth: 5_000,
    max_steps: 1_000_000,
    max_output_bytes: 10_000_000,
    max_total_fs_bytes: 100_000_000,
    max_exec_depth: 512,
    max_input_bytes: 256_000,
    max_tokens: 50_000,
    max_ast_nodes: 100_000,
    max_nesting_depth: 256,
    max_expanded_words: 50_000,
    max_http_body_bytes: 10_000_000,
    max_regex_pattern_bytes: 16_000,
    max_regex_input_bytes: 1_000_000,
    max_glob_matches: 50_000,
    max_file_walk_entries: 100_000,
    max_env_bytes: 1_000_000,
    max_array_entries: 100_000,
    max_array_bytes: 10_000_000,
    max_jq_results: 100_000,
    max_jq_depth: 256,
    max_jq_input_bytes: 10_000_000,
    max_jq_input_depth: 512,
    max_jq_work_items: 100_000,
    max_file_bytes: 10_000_000
  }

  @enforce_keys @all_keys
  defstruct Map.to_list(@defaults)

  @type t :: %__MODULE__{
          max_iterations: pos_integer(),
          max_call_depth: pos_integer(),
          max_exec_depth: pos_integer(),
          max_input_bytes: pos_integer(),
          max_tokens: pos_integer(),
          max_ast_nodes: pos_integer(),
          max_nesting_depth: pos_integer(),
          max_expanded_words: pos_integer(),
          max_http_body_bytes: pos_integer(),
          max_regex_pattern_bytes: pos_integer(),
          max_regex_input_bytes: pos_integer(),
          max_glob_matches: pos_integer(),
          max_file_walk_entries: pos_integer(),
          max_env_bytes: pos_integer(),
          max_array_entries: pos_integer(),
          max_array_bytes: pos_integer(),
          max_steps: pos_integer(),
          max_jq_results: pos_integer(),
          max_jq_depth: pos_integer(),
          max_jq_input_bytes: pos_integer(),
          max_jq_input_depth: pos_integer(),
          max_jq_work_items: pos_integer(),
          max_output_bytes: pos_integer(),
          max_file_bytes: pos_integer(),
          max_total_fs_bytes: pos_integer()
        }

  @doc """
  Builds a policy from a preset atom, keyword list, or existing struct.

  Accepts `:default`, `:strict`, `:relaxed`, a keyword list of overrides
  (with optional `:profile` key), `nil` (returns default), or an existing
  `Policy` struct (returned unchanged).

  Raises `ArgumentError` on unknown keys or non-positive-integer values.
  """
  @spec new(t() | :default | :strict | :relaxed | keyword() | nil) :: t()
  def new(%__MODULE__{} = policy), do: policy

  def new(spec) do
    {base, explicit_overrides} = normalize_security_spec(spec)

    base
    |> Map.merge(explicit_overrides)
    |> then(&struct(__MODULE__, &1))
  end

  @doc "Returns the default preset values as a plain map."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "Returns the user-facing option keys (the ones you'd typically tune)."
  @spec option_keys() :: [atom()]
  def option_keys, do: @public_keys

  @doc "Returns all option keys, including internal ones."
  @spec all_keys() :: [atom()]
  def all_keys, do: @all_keys

  @doc "Returns the preset values for `:default`, `:strict`, or `:relaxed` as a plain map."
  @spec preset(:default | :strict | :relaxed) :: map()
  def preset(:default), do: @defaults
  def preset(:strict), do: @strict
  def preset(:relaxed), do: @relaxed

  @doc "Fetches a single limit value from the policy embedded in a `JustBash` struct."
  @spec get(JustBash.t(), atom()) :: pos_integer()
  def get(%{security: %__MODULE__{} = policy}, key) do
    case Map.fetch(policy, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "unknown security policy key: #{inspect(key)}"
    end
  end

  defp normalize_security_spec(nil), do: {preset(:default), %{}}
  defp normalize_security_spec(:default), do: {preset(:default), %{}}
  defp normalize_security_spec(:strict), do: {preset(:strict), %{}}
  defp normalize_security_spec(:relaxed), do: {preset(:relaxed), %{}}

  defp normalize_security_spec(spec) when is_list(spec) do
    profile = Keyword.get(spec, :profile, :default)
    overrides = spec |> Keyword.drop([:profile]) |> Enum.into(%{})
    validate_overrides!(overrides)
    {preset(profile), overrides}
  end

  defp validate_overrides!(overrides) do
    unknown = Map.keys(overrides) -- @all_keys

    if unknown != [] do
      raise ArgumentError,
            "unknown security options: #{inspect(unknown)}. " <>
              "Common options: #{inspect(@public_keys)}"
    end

    invalid =
      Enum.reject(overrides, fn {_k, v} -> is_integer(v) and v > 0 end)

    if invalid != [] do
      keys = Enum.map(invalid, &elem(&1, 0))

      raise ArgumentError,
            "security options #{inspect(keys)} must be positive integers"
    end
  end
end
