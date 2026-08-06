defmodule JustBash.Limit do
  @moduledoc """
  Production resource limits for JustBash execution.

  Prevents untrusted scripts from exhausting memory or CPU by enforcing
  hard caps on computation steps, output size, file size, regex patterns,
  execution nesting depth, and elapsed wall clock time.

  ## Usage

      # Default limits (recommended for production)
      bash = JustBash.new()

      # Preset profiles
      bash = JustBash.new(limits: :strict)

      # Custom limits (merged with defaults)
      bash = JustBash.new(limits: [max_steps: 50_000])

      # No limits (not recommended for untrusted input)
      bash = JustBash.new(limits: false)

  ## Bounds

  | key | `:strict` | `:default` | `:relaxed` |
  | --- | --- | --- | --- |
  | `:max_steps` | 10_000 | 100_000 | 1_000_000 |
  | `:max_output_bytes` | 65_536 | 1_048_576 | 10_485_760 |
  | `:max_file_bytes` | 65_536 | 1_048_576 | 10_485_760 |
  | `:max_regex_pattern_bytes` | 10_000 | 10_000 | 10_000 |
  | `:max_exec_depth` | 128 | 128 | 128 |
  | `:max_wall_ms` | 1_000 | 5_000 | 30_000 |

  Every bound but the last counts work. `:max_wall_ms` bounds elapsed time for
  a single `JustBash.exec/2`, which is the only bound that catches a script
  that burns wall clock without doing countable work — the shape both of this
  project's historical hangs took. Nested `eval`/`source` run inside the
  top-level call's budget rather than starting a fresh one.
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
    - `:wall_clock_limit` — a single `JustBash.exec/2` ran too long
    """
    defexception [:kind, :message, :limit, :actual]
  end

  defmodule Deadline do
    @moduledoc """
    The instant a single `JustBash.exec/2` must be finished by.

    `at_ms` is read from `System.monotonic_time/1`, which never jumps
    backwards when the wall clock is adjusted, so a deadline armed once at the
    top of an execution stays meaningful for its whole duration. `max_wall_ms`
    is carried alongside purely so the diagnostic can name the bound that was
    breached.
    """

    @type t :: %__MODULE__{at_ms: integer(), max_wall_ms: pos_integer()}

    @enforce_keys [:at_ms, :max_wall_ms]
    defstruct [:at_ms, :max_wall_ms]
  end

  @enforce_keys [
    :max_steps,
    :max_output_bytes,
    :max_file_bytes,
    :max_regex_pattern_bytes,
    :max_exec_depth,
    :max_wall_ms
  ]
  defstruct [
    :max_steps,
    :max_output_bytes,
    :max_file_bytes,
    :max_regex_pattern_bytes,
    :max_exec_depth,
    :max_wall_ms
  ]

  @type t :: %__MODULE__{
          max_steps: pos_integer(),
          max_output_bytes: pos_integer(),
          max_file_bytes: pos_integer(),
          max_regex_pattern_bytes: pos_integer(),
          max_exec_depth: pos_integer(),
          max_wall_ms: pos_integer()
        }

  # 5 seconds: every script in this repo's corpus finishes in single-digit
  # milliseconds, so the default is three orders of magnitude of headroom —
  # generous enough that a legitimate script never trips it, small enough that
  # an agent waiting on the sandbox is never blocked for long.
  @default_values %{
    max_steps: 100_000,
    max_output_bytes: 1_048_576,
    max_file_bytes: 1_048_576,
    max_regex_pattern_bytes: 10_000,
    max_exec_depth: 128,
    max_wall_ms: 5_000
  }

  @valid_keys Map.keys(@default_values)

  @doc "Build limits from a preset atom, keyword list, or `false` to disable."
  @spec new(atom() | keyword() | false) :: t() | nil
  def new(false), do: nil
  def new(:default), do: defaults()

  def new(:strict),
    do: %{
      defaults()
      | max_steps: 10_000,
        max_output_bytes: 65_536,
        max_file_bytes: 65_536,
        max_wall_ms: 1_000
    }

  def new(:relaxed),
    do: %{
      defaults()
      | max_steps: 1_000_000,
        max_output_bytes: 10_485_760,
        max_file_bytes: 10_485_760,
        max_wall_ms: 30_000
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

  # --- Wall clock ---

  @doc """
  Arm a deadline for one top-level execution, or `nil` when limits are off.

  Call this once per `JustBash.exec/2` and carry the result; `check_deadline!/1`
  then costs a single monotonic clock read and an integer comparison, so it is
  affordable on the interpreter's statement loop.
  """
  @spec deadline(t() | nil) :: Deadline.t() | nil
  def deadline(nil), do: nil

  def deadline(%__MODULE__{max_wall_ms: max_wall_ms}) do
    %Deadline{at_ms: System.monotonic_time(:millisecond) + max_wall_ms, max_wall_ms: max_wall_ms}
  end

  @doc """
  Raise `ExceededError` if an armed deadline has passed.

  Accepts a `Deadline`, a `JustBash` struct carrying one, or `nil` for "no
  bound". Counting limits cannot see a loop that burns time without doing
  countable work, which is how both of this project's historical hangs escaped
  every other bound.
  """
  @spec check_deadline!(Deadline.t() | JustBash.t() | nil) :: :ok
  def check_deadline!(nil), do: :ok

  def check_deadline!(%Deadline{at_ms: at_ms, max_wall_ms: max_wall_ms}) do
    if System.monotonic_time(:millisecond) > at_ms do
      raise ExceededError,
        kind: :wall_clock_limit,
        message: "execution wall clock limit exceeded (#{max_wall_ms} ms)",
        limit: max_wall_ms,
        actual: elapsed_ms(at_ms, max_wall_ms)
    end

    :ok
  end

  def check_deadline!(%{interpreter: %{deadline: deadline}}), do: check_deadline!(deadline)

  defp elapsed_ms(at_ms, max_wall_ms),
    do: max_wall_ms + System.monotonic_time(:millisecond) - at_ms

  @doc """
  Wrap an enumerable so each element it yields first checks `deadline`.

  Used by `JustBash.FS.walk/3`: a traversal is a single command as far as the
  step counter is concerned, so without this a pathological tree is unbounded.
  """
  @spec enforce_deadline(Enumerable.t(), Deadline.t() | nil) :: Enumerable.t()
  def enforce_deadline(enumerable, nil), do: enumerable

  def enforce_deadline(enumerable, %Deadline{} = deadline) do
    Stream.map(enumerable, fn element ->
      check_deadline!(deadline)
      element
    end)
  end

  # --- Pure check functions (no state mutation) ---

  @doc """
  Check file data size before writing. Raises `ExceededError` if too large.

  Accepts the data binary, or a byte count for append-style writes where
  the resulting size is known without materializing the content.
  """
  @spec check_file_size!(JustBash.t(), String.t() | non_neg_integer()) :: :ok
  def check_file_size!(%{limits: nil}, _data), do: :ok

  def check_file_size!(bash, data) when is_binary(data) do
    check_file_size!(bash, byte_size(data))
  end

  def check_file_size!(%{limits: limits}, size) when is_integer(size) do
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
