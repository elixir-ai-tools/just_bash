defmodule JustBash.Result do
  @moduledoc """
  Represents the result of executing a command or script.

  Contains stdout, stderr, exit code, and optional control flow signals.

  ## Control Flow Signals

  Shell control flow (break, continue, return) is handled through the `signal` field:

  - `nil` - No signal, normal execution
  - `{:break, n}` - Break from n loop levels
  - `{:continue, n}` - Continue at n loop levels
  - `{:return, code}` - Return from function with exit code
  """

  @type signal ::
          {:break, pos_integer()}
          | {:continue, pos_integer()}
          | {:return, non_neg_integer()}
          | nil

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer(),
          signal: signal()
        }

  @enforce_keys [:stdout, :stderr, :exit_code]
  defstruct stdout: "", stderr: "", exit_code: 0, signal: nil

  @doc """
  Creates a new result with the given attributes.

  ## Examples

      iex> JustBash.Result.new()
      %JustBash.Result{stdout: "", stderr: "", exit_code: 0, signal: nil}

      iex> JustBash.Result.new(stdout: "hello\\n", exit_code: 0)
      %JustBash.Result{stdout: "hello\\n", stderr: "", exit_code: 0, signal: nil}
  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) do
    %__MODULE__{
      stdout: Keyword.get(attrs, :stdout, ""),
      stderr: Keyword.get(attrs, :stderr, ""),
      exit_code: Keyword.get(attrs, :exit_code, 0),
      signal: Keyword.get(attrs, :signal)
    }
  end

  @doc """
  Creates a successful result with the given stdout.
  """
  @spec ok(String.t()) :: t()
  def ok(stdout \\ "") do
    %__MODULE__{stdout: stdout, stderr: "", exit_code: 0, signal: nil}
  end

  @doc """
  Creates an error result with the given stderr and exit code.
  """
  @spec error(String.t(), non_neg_integer()) :: t()
  def error(stderr, exit_code \\ 1) do
    %__MODULE__{stdout: "", stderr: stderr, exit_code: exit_code, signal: nil}
  end

  @doc """
  Creates a result with a break signal.
  """
  @spec break(pos_integer()) :: t()
  def break(level \\ 1) when level > 0 do
    %__MODULE__{stdout: "", stderr: "", exit_code: 0, signal: {:break, level}}
  end

  @doc """
  Creates a result with a continue signal.
  """
  @spec continue(pos_integer()) :: t()
  def continue(level \\ 1) when level > 0 do
    %__MODULE__{stdout: "", stderr: "", exit_code: 0, signal: {:continue, level}}
  end

  @doc """
  Creates a result with a return signal.
  """
  @spec return(non_neg_integer()) :: t()
  def return(exit_code \\ 0) do
    %__MODULE__{stdout: "", stderr: "", exit_code: exit_code, signal: {:return, exit_code}}
  end

  @doc """
  Checks if the result has any control flow signal.
  """
  @spec has_signal?(t()) :: boolean()
  def has_signal?(%__MODULE__{signal: nil}), do: false
  def has_signal?(%__MODULE__{}), do: true

  @doc """
  Checks if the result has a break signal.
  """
  @spec break?(t()) :: boolean()
  def break?(%__MODULE__{signal: {:break, _}}), do: true
  def break?(%__MODULE__{}), do: false

  @doc """
  Checks if the result has a continue signal.
  """
  @spec continue?(t()) :: boolean()
  def continue?(%__MODULE__{signal: {:continue, _}}), do: true
  def continue?(%__MODULE__{}), do: false

  @doc """
  Checks if the result has a return signal.
  """
  @spec return?(t()) :: boolean()
  def return?(%__MODULE__{signal: {:return, _}}), do: true
  def return?(%__MODULE__{}), do: false

  @doc """
  Decrements the signal level by 1. Returns nil if level reaches 0.
  Only applicable to break and continue signals.
  """
  @spec decrement_signal(t()) :: t()
  def decrement_signal(%__MODULE__{signal: {:break, 1}} = result) do
    %{result | signal: nil}
  end

  def decrement_signal(%__MODULE__{signal: {:break, n}} = result) when n > 1 do
    %{result | signal: {:break, n - 1}}
  end

  def decrement_signal(%__MODULE__{signal: {:continue, 1}} = result) do
    %{result | signal: nil}
  end

  def decrement_signal(%__MODULE__{signal: {:continue, n}} = result) when n > 1 do
    %{result | signal: {:continue, n - 1}}
  end

  def decrement_signal(%__MODULE__{} = result), do: result

  @doc """
  Merges output from one result into another, preserving the signal from source if present.
  """
  @spec merge_output(t(), t()) :: t()
  def merge_output(target, source) do
    %__MODULE__{
      stdout: target.stdout <> source.stdout,
      stderr: target.stderr <> source.stderr,
      exit_code: source.exit_code,
      signal: source.signal || target.signal
    }
  end

  @doc """
  Converts to a plain map (for backward compatibility during migration).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    base = %{stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code}

    case result.signal do
      {:break, n} -> Map.put(base, :__break__, n)
      {:continue, n} -> Map.put(base, :__continue__, n)
      {:return, n} -> Map.put(base, :__return__, n)
      nil -> base
    end
  end

  @doc """
  Converts from a plain map (for backward compatibility during migration).
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    signal =
      cond do
        Map.has_key?(map, :__break__) -> {:break, map.__break__}
        Map.has_key?(map, :__continue__) -> {:continue, map.__continue__}
        Map.has_key?(map, :__return__) -> {:return, map.__return__}
        true -> nil
      end

    %__MODULE__{
      stdout: Map.get(map, :stdout, ""),
      stderr: Map.get(map, :stderr, ""),
      exit_code: Map.get(map, :exit_code, 0),
      signal: signal
    }
  end
end
