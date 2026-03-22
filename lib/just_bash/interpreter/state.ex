defmodule JustBash.Interpreter.State do
  @moduledoc """
  Internal interpreter state carried alongside the user-visible `JustBash` struct.

  This struct holds bookkeeping data that the interpreter needs during execution
  but that must never be visible to untrusted scripts. By keeping it separate
  from `bash.env`, scripts have no surface to observe or corrupt interpreter
  internals — not through `$VAR` expansion, not through `printenv`, not through
  `env`.

  ## Fields

  - `stdin` — pipeline stdin passed into a `while`/`until` loop body. The `read`
    builtin consumes it line by line, updating the remainder each iteration.

  - `locals` — a `MapSet` of variable names declared `local` inside the currently
    executing function. Used by `execute_function` to revert those variables to
    their caller values when the function returns.

  - `assoc_arrays` — a `MapSet` of variable names that have been declared as
    associative arrays (`declare -A`). Used during `${arr[key]}` expansion to
    decide whether to treat the subscript as a string key or integer index.

  - `call_depth` — current shell function call depth. Incremented on each
    function entry, decremented on return. Checked against `bash.max_call_depth`
    to prevent unbounded recursion from consuming all available memory.

  ## Nesting

  When a function is called, the interpreter saves the current `State` and
  installs a fresh one with `locals: MapSet.new()`. On return, the saved state
  is restored — but `assoc_arrays` is merged rather than discarded, since array
  declarations in the outer scope must remain visible.
  """

  @type t :: %__MODULE__{
          stdin: String.t() | nil,
          locals: MapSet.t(String.t()),
          assoc_arrays: MapSet.t(String.t()),
          call_depth: non_neg_integer()
        }

  defstruct stdin: nil,
            locals: MapSet.new(),
            assoc_arrays: MapSet.new(),
            call_depth: 0

  @doc "Returns a fresh interpreter state."
  @spec new() :: t()
  def new, do: %__MODULE__{}
end
