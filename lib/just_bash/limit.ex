defmodule JustBash.Limit do
  @moduledoc """
  Production resource limits for JustBash execution.

  Prevents untrusted scripts from exhausting memory or CPU by enforcing
  hard caps on computation steps, output size, file size, regex patterns,
  and execution nesting depth.

  ## Usage

      # Default limits (recommended for production)
      bash = JustBash.new()

      # Preset profiles
      bash = JustBash.new(limits: :strict)

      # Custom limits (merged with defaults)
      bash = JustBash.new(limits: [max_steps: 50_000])

      # No limits (not recommended for untrusted input)
      bash = JustBash.new(limits: false)
  """

  defmodule ExceededError do
    @moduledoc """
    Raised when a resource limit is exceeded during execution.

    ## Kinds

    - `:step_limit` — too many computation steps
    - `:output_limit` — stdout + stderr exceeded byte cap
    - `:file_size_limit` — single file write exceeded byte cap
    - `:regex_pattern_limit` — regex pattern string too large
    - `:exec_depth_limit` — eval/source nesting too deep
    """
    defexception [:kind, :message, :limit, :actual]
  end

  @enforce_keys [
    :max_steps,
    :max_output_bytes,
    :max_file_bytes,
    :max_regex_pattern_bytes,
    :max_exec_depth
  ]
  defstruct [
    :max_steps,
    :max_output_bytes,
    :max_file_bytes,
    :max_regex_pattern_bytes,
    :max_exec_depth
  ]

  @type t :: %__MODULE__{
          max_steps: pos_integer(),
          max_output_bytes: pos_integer(),
          max_file_bytes: pos_integer(),
          max_regex_pattern_bytes: pos_integer(),
          max_exec_depth: pos_integer()
        }

  @default_values %{
    max_steps: 100_000,
    max_output_bytes: 1_048_576,
    max_file_bytes: 1_048_576,
    max_regex_pattern_bytes: 10_000,
    max_exec_depth: 128
  }

  @valid_keys Map.keys(@default_values)

  @doc "Build limits from a preset atom, keyword list, or `false` to disable."
  @spec new(atom() | keyword() | false) :: t() | nil
  def new(false), do: nil
  def new(:default), do: defaults()

  def new(:strict),
    do: %{defaults() | max_steps: 10_000, max_output_bytes: 65_536, max_file_bytes: 65_536}

  def new(:relaxed),
    do: %{
      defaults()
      | max_steps: 1_000_000,
        max_output_bytes: 10_485_760,
        max_file_bytes: 10_485_760
    }

  def new(opts) when is_list(opts) do
    unknown = Keyword.keys(opts) -- @valid_keys

    if unknown != [] do
      raise ArgumentError, "unknown limit keys: #{inspect(unknown)}"
    end

    Enum.each(opts, fn {_k, v} ->
      unless is_integer(v) and v > 0 do
        raise ArgumentError, "limit values must be positive integers, got: #{inspect(opts)}"
      end
    end)

    struct!(defaults(), opts)
  end

  @doc "Returns the default limits."
  @spec defaults() :: t()
  def defaults, do: struct!(__MODULE__, @default_values)

  # --- Counting functions (always increment, enforce only when limits set) ---

  @doc "Increment step counter. Raises `ExceededError` if limit is reached."
  @spec step!(JustBash.t()) :: JustBash.t()
  def step!(%{interpreter: interp} = bash) do
    count = interp.step_count + 1

    if bash.limits && count > bash.limits.max_steps do
      raise ExceededError,
        kind: :step_limit,
        message: "execution step limit exceeded (#{bash.limits.max_steps})",
        limit: bash.limits.max_steps,
        actual: count
    end

    %{bash | interpreter: %{interp | step_count: count}}
  end

  @doc "Track output bytes. Raises `ExceededError` if limit is reached."
  @spec track_output!(JustBash.t(), non_neg_integer()) :: JustBash.t()
  def track_output!(%{interpreter: interp} = bash, new_bytes) do
    total = interp.output_bytes + new_bytes

    if bash.limits && total > bash.limits.max_output_bytes do
      raise ExceededError,
        kind: :output_limit,
        message: "output size limit exceeded (#{bash.limits.max_output_bytes} bytes)",
        limit: bash.limits.max_output_bytes,
        actual: total
    end

    %{bash | interpreter: %{interp | output_bytes: total}}
  end

  @doc "Increment exec depth and track the high-water mark. Raises `ExceededError` if limit is exceeded."
  @spec track_exec_depth!(JustBash.t()) :: JustBash.t()
  def track_exec_depth!(%{interpreter: interp} = bash) do
    depth = interp.exec_depth + 1
    max_depth = max(depth, interp.max_exec_depth)

    if bash.limits && depth > bash.limits.max_exec_depth do
      raise ExceededError,
        kind: :exec_depth_limit,
        message: "execution nesting depth exceeded (#{bash.limits.max_exec_depth})",
        limit: bash.limits.max_exec_depth,
        actual: depth
    end

    %{bash | interpreter: %{interp | exec_depth: depth, max_exec_depth: max_depth}}
  end

  # --- Pure check functions (no state mutation) ---

  @doc "Check file data size before writing. Raises `ExceededError` if too large."
  @spec check_file_size!(JustBash.t(), String.t()) :: :ok
  def check_file_size!(%{limits: nil}, _data), do: :ok

  def check_file_size!(%{limits: limits}, data) do
    size = byte_size(data)

    if size > limits.max_file_bytes do
      raise ExceededError,
        kind: :file_size_limit,
        message: "file size limit exceeded (#{limits.max_file_bytes} bytes)",
        limit: limits.max_file_bytes,
        actual: size
    end

    :ok
  end

  @doc """
  Check regex pattern size and compile. Raises `ExceededError` if pattern too large.

  Centralizes the check-then-compile pattern used across commands (grep, sed, awk, jq, etc.).
  Accepts a limits struct (not a full bash struct) so it can be called from
  command internals that don't carry the full struct.
  """
  @spec compile_regex(t() | nil, String.t(), String.t() | [atom()]) ::
          {:ok, Regex.t()} | {:error, term()}
  def compile_regex(limits, pattern, opts \\ "") do
    check_regex_size!(limits, pattern)
    Regex.compile(pattern, opts)
  end

  @doc """
  Check regex pattern size only. Use `compile_regex/3` when you also need compilation.

  For call sites that need custom compilation logic (e.g. grep's flag handling,
  sed's BRE-to-ERE conversion), call this directly.
  """
  @spec check_regex_size!(t() | nil, String.t()) :: :ok
  def check_regex_size!(nil, _pattern), do: :ok

  def check_regex_size!(%__MODULE__{} = limits, pattern) do
    size = byte_size(pattern)

    if size > limits.max_regex_pattern_bytes do
      raise ExceededError,
        kind: :regex_pattern_limit,
        message: "regex pattern size limit exceeded (#{limits.max_regex_pattern_bytes} bytes)",
        limit: limits.max_regex_pattern_bytes,
        actual: size
    end

    :ok
  end
end
