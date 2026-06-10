defmodule JustBash.CLI.Command do
  @moduledoc """
  A single node in a `JustBash.CLI` command tree.

  A node is either:

    * a **group** — has nested `commands` and no `run` handler (it routes to children), or
    * a **leaf** — has a `run` handler and no nested `commands` (it does the work).

  Build nodes with `JustBash.CLI.command/2` rather than constructing the struct directly,
  so validation runs.

  ## Fields

    * `:name` — the token used to route to this node (e.g. `"review"`)
    * `:doc` — one-line description shown in help output
    * `:flags` — a `JustBash.Commands.ArgParser` flag spec (keyword list); leaves only
    * `:args` — positional argument specs (see `t:arg_spec/0`); leaves only
    * `:commands` — nested child nodes (groups only)
    * `:run` — the handler, `(JustBash.CLI.Invocation.t() -> {map(), JustBash.t()})`; leaves only
  """

  @enforce_keys [:name]
  defstruct name: nil, doc: nil, flags: [], args: [], commands: [], run: nil

  @typedoc """
  A positional argument specification.

    * `:name` — atom name (also the display label)
    * `:doc` — one-line description
    * `:required` — whether the argument must be present (default `false`)
    * `:variadic` — when `true`, captures all remaining positionals (default `false`)
  """
  @type arg_spec :: %{
          required(:name) => atom(),
          optional(:doc) => String.t(),
          optional(:required) => boolean(),
          optional(:variadic) => boolean()
        }

  @type handler :: (JustBash.CLI.Invocation.t() -> {map(), JustBash.t()})

  @type t :: %__MODULE__{
          name: String.t(),
          doc: String.t() | nil,
          flags: keyword(),
          args: [arg_spec()],
          commands: [t()],
          run: handler() | nil
        }

  @doc """
  Returns `true` when the node routes to children rather than running a handler.
  """
  @spec group?(t()) :: boolean()
  def group?(%__MODULE__{run: nil}), do: true
  def group?(%__MODULE__{}), do: false

  @doc """
  Returns `true` when the node runs a handler.
  """
  @spec leaf?(t()) :: boolean()
  def leaf?(%__MODULE__{} = command), do: not group?(command)
end
