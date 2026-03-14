defmodule JustBash.Eval.Task do
  @moduledoc """
  Behaviour for eval task modules. Each module provides a list of task definitions.
  """

  @type task :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:files) => %{String.t() => String.t()},
          required(:validators) => [JustBash.Eval.Validator.validator()],
          optional(:commands) => %{String.t() => module()}
        }

  @callback tasks() :: [task()]
end
