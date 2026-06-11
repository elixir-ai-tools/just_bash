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
    * `:examples` — worked examples surfaced in help, `describe/1`, and docs (see `t:example/0`)
    * `:commands` — nested child nodes (groups only)
    * `:run` — the handler, `(JustBash.CLI.Invocation.t() -> {map(), JustBash.t()})`; leaves only
    * `:validate` — optional `(JustBash.CLI.Invocation.t() -> :ok | {:error, String.t()})`
      run after parsing and before `:run`; an error yields the same exit-2 + usage line as a
      flag error (leaves only)
    * `:allow_unknown_flags` — when `true`, undeclared flags are collected into
      `Invocation.extra_flags` instead of erroring (leaves only)
    * `:visible?` — optional `(JustBash.t() -> boolean())` predicate; when it returns `false`
      the node is **absent** (unroutable and omitted from help/`describe`) for that caller
    * `:on_missing_subcommand` — `:error` (default) or `:help`; what a bare group does when
      invoked without a subcommand (groups and the root only)
  """

  @enforce_keys [:name]
  defstruct name: nil,
            doc: nil,
            flags: [],
            args: [],
            examples: [],
            commands: [],
            run: nil,
            validate: nil,
            allow_unknown_flags: false,
            visible?: nil,
            on_missing_subcommand: :error

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

  @typedoc """
  A worked example, normalized to a map. `:cmd` is the example invocation; `:doc` is an
  optional one-line description.
  """
  @type example :: %{cmd: String.t(), doc: String.t() | nil}

  @type handler :: (JustBash.CLI.Invocation.t() -> {map(), JustBash.t()})
  @type validator :: (JustBash.CLI.Invocation.t() -> :ok | {:error, String.t()})
  @type visibility :: (JustBash.t() -> boolean())

  @type t :: %__MODULE__{
          name: String.t(),
          doc: String.t() | nil,
          flags: keyword(),
          args: [arg_spec()],
          examples: [example()],
          commands: [t()],
          run: handler() | nil,
          validate: validator() | nil,
          allow_unknown_flags: boolean(),
          visible?: visibility() | nil,
          on_missing_subcommand: :error | :help
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
