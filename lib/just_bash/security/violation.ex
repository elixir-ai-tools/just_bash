defmodule JustBash.Security.Violation do
  @moduledoc """
  Typed description of a security or quota violation.
  """

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, metadata: %{}]

  @type t :: %__MODULE__{
          kind: atom(),
          message: String.t(),
          metadata: map()
        }
end
