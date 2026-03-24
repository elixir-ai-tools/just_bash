defmodule JustBash.Security.Budget do
  @moduledoc """
  Mutable execution accounting for a single top-level run.
  """

  alias JustBash.Security.Violation

  defstruct output_bytes: 0,
            step_count: 0,
            violation: nil

  @type t :: %__MODULE__{
          output_bytes: non_neg_integer(),
          step_count: non_neg_integer(),
          violation: Violation.t() | nil
        }

  @doc "Returns a fresh budget with all counters at zero and no violation."
  @spec new() :: t()
  def new, do: %__MODULE__{}
end
