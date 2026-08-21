defmodule JustBash.Limit do
  @moduledoc """
  Production resource limits for JustBash execution.

  Prevents untrusted scripts from exhausting memory or CPU by enforcing
  hard caps on computation steps, output size, file size, value size, regex
  patterns, execution nesting depth, and elapsed wall clock time.

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
  | `:max_value_bytes` | 65_536 | 1_048_576 | 10_485_760 |
  | `:max_regex_pattern_bytes` | 10_000 | 10_000 | 10_000 |
  | `:max_exec_depth` | 128 | 128 | 128 |
  | `:max_wall_ms` | 1_000 | 5_000 | 30_000 |

  Every bound but the last counts work. `:max_wall_ms` bounds elapsed time for
  a single `JustBash.exec/2`, which is the only bound that catches a script
  that burns wall clock without doing countable work — the shape both of this
  project's historical hangs took. Nested `eval`/`source` run inside the
  top-level call's budget rather than starting a fresh one.

  `:max_steps` does double duty: a whole word is one step no matter what it
  expands into, so it is also the cap on how many words a single word may
  expand into — see `check_expansion_words!/2`.

  `:max_value_bytes` bounds a single expanded value. A step like
  `v=${v}${v}` doubles a binary with no other bound seeing inside it, and
  `${v//a/$r}` can grow a value by the product of two already-capped
  binaries, so without this cap the wall clock cannot fire until that
  allocation finishes. Call `concat!/3` or `replace!/5` (or
  `check_value_size!/2` with a byte count) before the memory is spent, the
  way `check_expansion_words!/2` is called as a word list is produced.
  """

  defmodule ExceededError do
    @moduledoc """
    Raised when a resource limit is exceeded during execution.

    ## Kinds

    - `:step_limit` — too many computation steps
    - `:expansion_limit` — one word expanded into too many words
    - `:output_limit` — stdout + stderr exceeded byte cap
    - `:file_size_limit` — single file write exceeded byte cap
    - `:value_size_limit` — a single expanded value exceeded byte cap
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
    :max_value_bytes,
    :max_regex_pattern_bytes,
    :max_exec_depth,
    :max_wall_ms
  ]
  defstruct [
    :max_steps,
    :max_output_bytes,
    :max_file_bytes,
    :max_value_bytes,
    :max_regex_pattern_bytes,
    :max_exec_depth,
    :max_wall_ms
  ]

  @type t :: %__MODULE__{
          max_steps: pos_integer(),
          max_output_bytes: pos_integer(),
          max_file_bytes: pos_integer(),
          max_value_bytes: pos_integer(),
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
    max_value_bytes: 1_048_576,
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
        max_value_bytes: 65_536,
        max_wall_ms: 1_000
    }

  def new(:relaxed),
    do: %{
      defaults()
      | max_steps: 1_000_000,
        max_output_bytes: 10_485_760,
        max_file_bytes: 10_485_760,
        max_value_bytes: 10_485_760,
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

  @doc """
  Bound how many words one word may expand into. Raises `ExceededError` if exceeded.

  The step counter cannot see this: a word is a single step regardless of the
  size of the list it names, so `{1..1000000}` — twelve characters — is one
  step and a million words. That is counted work, not merely slow work, so the
  bound is `:max_steps` rather than the wall clock; the clock is checked
  alongside it so a budget large enough to permit the list still cannot be
  spent entirely on building it.

  Call this with the running count as the list is produced, not with the
  finished list's length — the point is to refuse before the memory is spent.
  """
  @spec check_expansion_words!(JustBash.t(), non_neg_integer()) :: :ok
  def check_expansion_words!(%{limits: nil}, _count), do: :ok

  def check_expansion_words!(%{limits: limits}, count) do
    if count > limits.max_steps do
      raise ExceededError,
        kind: :expansion_limit,
        message: "word expansion limit exceeded (#{limits.max_steps} words)",
        limit: limits.max_steps,
        actual: count
    end

    :ok
  end

  @doc """
  Concatenate two binaries, raising `ExceededError` if the result would
  exceed `:max_value_bytes`.

  The check is on the sum of the sizes, so the oversized result is never
  allocated — a single `v=${v}${v}` of a multi-gigabyte value is the hole
  this closes. Call this as word parts are joined, not with the finished
  binary.
  """
  @spec concat!(JustBash.t(), binary(), binary()) :: binary()
  def concat!(%{limits: nil}, left, right) when is_binary(left) and is_binary(right) do
    left <> right
  end

  def concat!(bash, left, right) when is_binary(left) and is_binary(right) do
    check_value_size!(bash, byte_size(left) + byte_size(right))
    left <> right
  end

  @doc """
  Replace matches of `regex` in `str` with `replacement`, raising
  `ExceededError` if the result would exceed `:max_value_bytes`.

  The check is on the projected size from match lengths, so the oversized
  result is never allocated — a single `${v//a/$r}` of cap-sized `v` and
  `r` is the hole this closes. Call this instead of `Regex.replace/4`.
  """
  @spec replace!(JustBash.t(), Regex.t(), binary(), binary(), keyword()) :: binary()
  def replace!(bash, regex, str, replacement, opts \\ [])

  def replace!(%{limits: nil}, %Regex{} = regex, str, replacement, opts)
      when is_binary(str) and is_binary(replacement) and is_list(opts) do
    Regex.replace(regex, str, replacement, opts)
  end

  def replace!(bash, %Regex{} = regex, str, replacement, opts)
      when is_binary(str) and is_binary(replacement) and is_list(opts) do
    global = Keyword.get(opts, :global, true)
    check_replace_size!(bash, str, regex, replacement, global)
    Regex.replace(regex, str, replacement, opts)
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

  Used by `JustBash.Commands.Seq`: a whole command is a single step as far as
  the step counter is concerned, so without this `seq 1 100000000` is
  unbounded. Commands whose loop is not already an enumerable call
  `check_deadline!/1` directly instead — see `JustBash.Commands.Find`.
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
  Check a value's size before keeping it. Raises `ExceededError` if too large.

  Accepts the data binary, or a byte count so callers can refuse a
  concatenation or replacement before it is built — see `concat!/3` and
  `replace!/5`.
  """
  @spec check_value_size!(JustBash.t(), String.t() | non_neg_integer()) :: :ok
  def check_value_size!(%{limits: nil}, _data), do: :ok

  def check_value_size!(bash, data) when is_binary(data) do
    check_value_size!(bash, byte_size(data))
  end

  def check_value_size!(%{limits: limits}, size) when is_integer(size) do
    if size > limits.max_value_bytes do
      raise ExceededError,
        kind: :value_size_limit,
        message: "value size limit exceeded (#{limits.max_value_bytes} bytes)",
        limit: limits.max_value_bytes,
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

  # Project the size of a Regex.replace/4 before it runs, aborting as soon as
  # the running total exceeds the cap so `${v//a/$r}` of cap-sized inputs
  # cannot spend the wall clock (or the VM) building a terabyte-scale binary.
  defp check_replace_size!(bash, str, regex, replacement, global) do
    str_size = byte_size(str)
    rep_size = byte_size(replacement)

    cheap_upper =
      if global do
        str_size + (str_size + 1) * rep_size
      else
        str_size + rep_size
      end

    if cheap_upper <= bash.limits.max_value_bytes do
      :ok
    else
      check_value_size!(
        bash,
        projected_replace_size(str, regex, replacement, global, bash.limits.max_value_bytes)
      )
    end
  end

  defp projected_replace_size(str, regex, replacement, global, max_bytes) do
    do_projected_replace_size(
      str,
      Regex.re_pattern(regex),
      byte_size(replacement),
      global,
      0,
      byte_size(str),
      max_bytes
    )
  end

  defp do_projected_replace_size(_str, _re, _rep_size, _global, _offset, projected, max_bytes)
       when projected > max_bytes,
       do: projected

  defp do_projected_replace_size(str, _re, _rep_size, _global, offset, projected, _max_bytes)
       when offset > byte_size(str),
       do: projected

  defp do_projected_replace_size(str, re, rep_size, global, offset, projected, max_bytes) do
    case :re.run(str, re, [{:capture, :first, :index}, {:offset, offset}]) do
      :nomatch ->
        projected

      {:match, [{start, len} | _]} ->
        next_projected = projected - len + rep_size
        next_offset = start + max(len, 1)

        if global do
          do_projected_replace_size(
            str,
            re,
            rep_size,
            global,
            next_offset,
            next_projected,
            max_bytes
          )
        else
          next_projected
        end
    end
  end
end
