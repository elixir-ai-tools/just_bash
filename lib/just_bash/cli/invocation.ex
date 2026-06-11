defmodule JustBash.CLI.Invocation do
  @moduledoc """
  The single argument passed to a `JustBash.CLI` command handler.

  A handler is a one-argument function that receives an `%Invocation{}` and returns
  `{result, bash}` — exactly the contract of `c:JustBash.Commands.Command.execute/3`.

      def review(%JustBash.CLI.Invocation{flags: flags, bash: bash}) do
        report = MyApp.PullRequests.fetch!(flags.report, bash.context.user)
        {JustBash.Commands.Command.ok(render(report, flags.format)), bash}
      end

  ## Fields

    * `:bash` — the full `t:JustBash.t/0` struct (fs, env, context, …)
    * `:flags` — a map of parsed flag values, keyed by the flag's atom name
    * `:args` — the remaining positional arguments, as a list of strings
    * `:extra_flags` — undeclared flag tokens collected when the leaf sets
      `allow_unknown_flags: true`, as a raw list of strings (empty otherwise); ready to
      forward verbatim to a backend
    * `:stdin` — the command's stdin, as a string
    * `:path` — the resolved subcommand path that routed here, e.g. `["pr", "review"]`
  """

  @enforce_keys [:bash, :flags, :args, :stdin, :path]
  defstruct [:bash, :flags, :args, :stdin, :path, extra_flags: []]

  @type t :: %__MODULE__{
          bash: JustBash.t(),
          flags: %{optional(atom()) => term()},
          args: [String.t()],
          extra_flags: [String.t()],
          stdin: String.t(),
          path: [String.t()]
        }
end
