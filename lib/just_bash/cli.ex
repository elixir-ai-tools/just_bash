defmodule JustBash.CLI do
  @moduledoc """
  Declarative, namespaced subcommand tools for JustBash.

  `JustBash.CLI` turns a tree of subcommands — like `acme pr review --report 1234` — into
  a single value you register in the `:commands` map. It handles **routing**, **typed
  argument parsing**, and **auto-generated help and errors**, so host applications stop
  hand-rolling `case`-statement routers and hand-maintained `--help` text.

  A CLI is plain data: a `%JustBash.CLI{}` holding a tree of `JustBash.CLI.Command` nodes.
  Build it with `new/2` and `command/2`, then register the struct directly:

      alias JustBash.CLI

      cli =
        CLI.new("acme", doc: "Acme operations toolkit", commands: [
          CLI.command("pr", doc: "Pull request management", commands: [
            CLI.command("review",
              doc: "Review a pull request",
              flags: [
                report:  [type: :integer, required: true, doc: "ID of the report to review"],
                format:  [type: :string, default: "text", values: ~w(text json), doc: "Output format"],
                verbose: [type: :boolean, short: "-v"]
              ],
              run: &Acme.PR.review/1)
          ])
        ])

      bash = JustBash.new(commands: %{"acme" => cli})

  Each leaf's `:run` is a one-argument handler that receives a
  `JustBash.CLI.Invocation` and returns `{result, bash}` — the same contract as a
  custom `JustBash.Commands.Command`:

      def review(%JustBash.CLI.Invocation{flags: flags, bash: bash}) do
        report = MyApp.PullRequests.fetch!(flags.report, bash.context.user)
        {JustBash.Commands.Command.ok(render(report, flags.format)), bash}
      end

  ## Flags

  Flag specs use the exact shape of `JustBash.Commands.ArgParser`: a keyword list of
  `name: [type: ..., ...]`. Supported keys: `:type` (`:boolean`, `:string`, `:integer`,
  `:float`, `:accumulator`), `:short`, `:long` (defaults to `--name`), `:default`,
  `:required`, `:values` (enum), `:transform`, and `:doc` (used in help output).

  Flag specs are validated at build time (`command/2` raises `ArgumentError`):

    * `--help`/`-h` are **reserved** — see "Reserved flags" below.
    * `:required` and `:default` are mutually exclusive (a required flag errors when omitted,
      so the default could never apply).
    * a `:default` must be a member of `:values` when both are given (the enum check only
      runs on flags the user actually provides, so an out-of-range default would slip past it).

  `:values` is compared against the **coerced** value, so list members must match the flag's
  `:type` — e.g. `type: :integer, values: [1, 2]` (integers, not `~w(1 2)`). The raw
  `:values` list is also what `describe/1` and the help text surface to agents.

  Flag names are atoms, so a name that is an Elixir reserved word (e.g. `end`, `fn`, `do`)
  can't be written bare in the keyword list. Give it an explicit `:long` instead:
  `end_date: [type: :string, long: "--end"]`.

  Beyond required-ness, types, and `:values`, two hooks cover custom validation, both
  producing the same exit-2 + usage-line failure as a flag error:

    * a flag's `:transform` may return `{:error, message}` for single-field checks (a numeric
      range, a parseable date);
    * a command-level `:validate` callback runs after parsing for cross-field rules
      (`start <= end`). See `command/2`.

  ## Passthrough flags

  A leaf that wraps a backend whose flags aren't known at definition time can set
  `allow_unknown_flags: true`. Undeclared flags are then collected into
  `Invocation.extra_flags` as a raw token list (ready to forward verbatim) instead of
  erroring, while declared flags and positionals are parsed as usual. Put declared
  positionals before passthrough flags, and prefer `--flag=value` form for unambiguous
  forwarding. See `command/2`.

  ## Authorization

  To make a subtree **present only for some callers** — genuinely absent, not just hidden —
  there are two approaches:

    * **Build the tree from context (first-class).** A `%JustBash.CLI{}` is plain data, so
      build it per session and conditionally append gated groups based on `bash.context`
      before registering it. Routing, help, and `describe/1` all reflect exactly the tree
      you built. This is the most flexible path and the right one for fully dynamic trees.
    * **A `:visible?` predicate (declarative sugar).** Attach `visible?: fn bash -> ... end`
      to a node; `run/4` prunes nodes the predicate rejects before routing, so they're
      unroutable (reported as unknown commands) and omitted from help. Pass the same `bash`
      to `describe/2`/`render_docs/2` to get the catalog as that caller sees it.

  ## Reserved flags

  `--help` and `-h` are reserved: the router intercepts them before a leaf ever parses, so a
  leaf can request help in one turn. A flag spec may not claim either form (including a flag
  named `:help`, whose derived long is `--help`) — `command/2` raises if it does. Because
  interception happens first, `--help`/`-h` anywhere before a `--` terminator wins even when
  it would otherwise be a flag's value (e.g. `acme pr review --format -h` shows help).

  ## `--` handling

  A leading `--` *before* a subcommand is consumed and routing continues (`acme -- pr review`
  reaches `pr review`), so wrappers that prepend `--` still route. This is intentionally not
  POSIX `--` semantics — `--` only acts as an options/help terminator once routing reaches a
  leaf and hands the remaining tokens to the parser.

  ## Positional arguments

  Positionals are a flat list, so `command/2` rejects ambiguous shapes at build time: a
  required positional may not follow an optional one, and a variadic must be last. A lone
  `-` (the stdin convention) is treated as a flag by the router and is **not** supported as a
  positional; pass it after `--` if a leaf needs it as a literal value.

  ## Trust model

  CLI handlers are ordinary host Elixir code with the same trust model and crash
  isolation as any custom command — they are **not** sandboxed. A crashing handler is
  caught and turned into an error result, but it runs with full access to the host.
  """

  alias JustBash.CLI.Command
  alias JustBash.CLI.Docs
  alias JustBash.CLI.Help
  alias JustBash.CLI.Invocation
  alias JustBash.Commands.ArgParser

  # Exit code used for all usage errors (unknown command, bad flags, missing args),
  # matching the convention of git/most CLIs.
  @usage_exit 2

  @enforce_keys [:name]
  defstruct name: nil, doc: nil, commands: [], aliases: [], on_missing_subcommand: :error

  @type t :: %__MODULE__{
          name: String.t(),
          doc: String.t() | nil,
          commands: [Command.t()],
          aliases: [String.t()],
          on_missing_subcommand: :error | :help
        }

  @typedoc "A CLI value: either a built struct or a module that `use`s `JustBash.CLI`."
  @type spec :: t() | module()

  @doc """
  Returns the CLI definition. Implemented for you when you `use JustBash.CLI`; you supply
  `spec/0`.
  """
  @callback spec() :: t()

  @doc """
  Make a module *be* a CLI command, so it can live alongside other
  `JustBash.Commands.Command` modules and be registered by module name:

      defmodule Acme.CLI do
        use JustBash.CLI

        @impl true
        def spec do
          JustBash.CLI.new("acme", doc: "Acme toolkit", commands: [...])
        end
      end

      bash = JustBash.new(commands: %{"acme" => Acme.CLI})

  This injects a `JustBash.Commands.Command`-compatible `names/0` and `execute/3` that
  delegate to your `spec/0`. It is conventional `use`-wiring (like `use GenServer`), not a
  DSL — the definition is still the plain `%JustBash.CLI{}` you return from `spec/0`.

  Registering the struct directly (`%{"acme" => Acme.CLI.spec()}`) works too and skips the
  module entirely; both run on the same engine.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour JustBash.Commands.Command
      @behaviour JustBash.CLI

      @impl JustBash.Commands.Command
      def names do
        s = spec()
        [s.name | s.aliases]
      end

      @impl JustBash.Commands.Command
      def execute(bash, args, stdin), do: JustBash.CLI.run(spec(), bash, args, stdin)

      defoverridable names: 0
    end
  end

  @doc """
  Returns `true` if `value` is a CLI — a `%JustBash.CLI{}` struct or a module that
  `use`s `JustBash.CLI`.
  """
  @spec cli?(term()) :: boolean()
  def cli?(%__MODULE__{}), do: true
  def cli?(module) when is_atom(module), do: cli_module?(module)
  def cli?(_), do: false

  @doc """
  A human description of a registered custom-command `value`, for `type` and `command -V`.

  CLI values report their subcommand count (`"acme is a CLI tool (12 commands)"`); plain
  command modules fall back to bash's terse `"name is name"`.
  """
  @spec custom_command_description(term(), String.t()) :: String.t()
  def custom_command_description(value, name) do
    if cli?(value) do
      # `describe/1` flattens to leaves only (groups are recursed into, not listed), so this
      # counts runnable commands, not tree nodes. If `describe/1`'s shape ever changes, the
      # "describes a CLI tool" tests in test/cli/shell_integration_test.exs pin this count.
      count = value |> describe() |> Map.fetch!(:commands) |> length()
      "#{name} is a CLI tool (#{count} #{pluralize(count, "command", "commands")})"
    else
      "#{name} is #{name}"
    end
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_, _singular, plural), do: plural

  @doc """
  Returns `true` if `module` `use`s `JustBash.CLI`.
  """
  @spec cli_module?(module()) :: boolean()
  def cli_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spec, 0) and
      __MODULE__ in module_behaviours(module)
  end

  defp module_behaviours(module) do
    module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  rescue
    _ -> []
  end

  # Resolve a struct or `use`-module to the underlying %JustBash.CLI{}.
  defp resolve(%__MODULE__{} = cli), do: cli
  defp resolve(module) when is_atom(module), do: module.spec()

  @doc """
  Build a CLI tool rooted at `name`.

  ## Options

    * `:doc` — one-line description of the tool
    * `:commands` — a list of top-level `JustBash.CLI.Command` nodes (built with `command/2`)
    * `:aliases` — additional names the tool can be registered under
    * `:on_missing_subcommand` — `:error` (default) or `:help`; what the root does when
      invoked with no subcommand (see `command/2`)

  Raises `ArgumentError` if names are invalid or top-level command names collide.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts \\ []) when is_binary(name) do
    validate_name!(name, "CLI")

    commands = Keyword.get(opts, :commands, [])
    validate_commands!(commands)
    validate_unique_names!(commands, name)

    aliases = Keyword.get(opts, :aliases, [])
    validate_aliases!(aliases)

    on_missing = Keyword.get(opts, :on_missing_subcommand, :error)
    validate_on_missing!(name, on_missing)

    %__MODULE__{
      name: name,
      doc: Keyword.get(opts, :doc),
      commands: commands,
      aliases: aliases,
      on_missing_subcommand: on_missing
    }
  end

  @doc """
  Build a single command node.

  A node is a **group** (routes to children) when given `:commands`, or a **leaf** (does
  work) when given `:run`. Exactly one of the two must be provided.

  ## Options

    * `:doc` — one-line description shown in help output
    * `:commands` — nested child nodes (makes this a group)
    * `:run` — a one-arg handler `(JustBash.CLI.Invocation.t() -> {map(), JustBash.t()})`
      (makes this a leaf)
    * `:flags` — an `ArgParser` flag spec (leaves only)
    * `:args` — positional argument specs (leaves only); see `t:JustBash.CLI.Command.arg_spec/0`
    * `:examples` — a list of worked examples (leaves only); each is a string or a map
      `%{cmd: String.t(), doc: String.t() | nil}`, surfaced in help, `describe/1`, and docs
    * `:validate` — a `(JustBash.CLI.Invocation.t() -> :ok | {:error, String.t()})` callback
      (leaves only) run after parsing and before `:run`; an `{:error, msg}` produces the same
      exit-2 + usage line as a flag error, giving cross-field validation a home
    * `:allow_unknown_flags` — when `true` (leaves only), undeclared flags are collected into
      `Invocation.extra_flags` (a raw token list) instead of erroring. Declared positionals
      should precede passthrough flags, and `--flag=value` is forwarded as one token
    * `:visible?` — a `(JustBash.t() -> boolean())` predicate; when it returns `false` the
      node is **absent** for that caller — unroutable (reported as an unknown command) and
      omitted from help and `describe/2`
    * `:on_missing_subcommand` — `:error` (default) or `:help` (groups only); `:help` prints
      the command listing at exit 0 instead of a usage error when the group is invoked bare

  Raises `ArgumentError` on invalid shape (e.g. both or neither of `:commands`/`:run`).
  """
  @spec command(String.t(), keyword()) :: Command.t()
  def command(name, opts \\ []) when is_binary(name) do
    validate_name!(name, "command")

    commands = Keyword.get(opts, :commands, [])
    run = Keyword.get(opts, :run)
    flags = Keyword.get(opts, :flags, [])
    args = Keyword.get(opts, :args, [])
    examples = Keyword.get(opts, :examples, [])
    validate = Keyword.get(opts, :validate)
    allow_unknown_flags = Keyword.get(opts, :allow_unknown_flags, false)
    visible? = Keyword.get(opts, :visible?)
    on_missing = Keyword.get(opts, :on_missing_subcommand, :error)

    validate_node_kind!(name, commands, run)
    validate_leaf_only!(name, commands, flags, args)
    reject_on_group!(name, commands, :examples, examples, [])
    reject_on_group!(name, commands, :validate, validate, nil)
    reject_on_group!(name, commands, :allow_unknown_flags, allow_unknown_flags, false)
    reject_on_leaf!(name, run, :on_missing_subcommand, on_missing, :error)
    validate_commands!(commands)
    validate_unique_names!(commands, name)
    validate_callback!(name, :validate, validate)
    validate_callback!(name, :visible?, visible?)
    validate_boolean!(name, :allow_unknown_flags, allow_unknown_flags)
    validate_on_missing!(name, on_missing)
    flags = normalize_flags!(name, flags)
    args = validate_args!(name, args)
    examples = normalize_examples!(name, examples)

    %Command{
      name: name,
      doc: Keyword.get(opts, :doc),
      flags: flags,
      args: args,
      examples: examples,
      commands: commands,
      run: run,
      validate: validate,
      allow_unknown_flags: allow_unknown_flags,
      visible?: visible?,
      on_missing_subcommand: on_missing
    }
  end

  @doc """
  Run a CLI against raw arguments.

  Routes `args` through the command tree, parses the matched leaf's flags and
  positionals, and invokes its handler. Returns `{result, bash}` — the same shape as
  `c:JustBash.Commands.Command.execute/3`.

  Usage problems (unknown subcommand, bad flag, missing argument) return an error result
  with exit code `2` and a usage hint, rather than raising. A command-level `:validate`
  failure uses the same exit-2 + usage-line shape.

  Nodes whose `:visible?` predicate rejects this `bash` are pruned before routing, so they
  are reported as unknown commands and never appear in help (see the moduledoc's
  "Authorization" section).

  > #### Result carries `:__subcommand__` {: .info}
  > The returned `result` map includes a `:__subcommand__` key holding the resolved path,
  > for command telemetry. The shell executor reads it into span metadata and strips it
  > before the result reaches the shell, but a host calling `run/4` (or `invoke/5`) directly
  > will see it. It's safe to ignore — read `:exit_code`/`:stdout`/`:stderr` as usual.
  """
  @spec run(t(), JustBash.t(), [String.t()], String.t()) :: {map(), JustBash.t()}
  def run(%__MODULE__{} = cli, bash, args, stdin) do
    # Prune nodes hidden from this caller (by their `:visible?` predicate) once up front, so
    # routing, help, and errors all operate on the same caller-specific view of the tree.
    cli = prune_visible(cli, bash)

    # Every routed result carries its resolved subcommand path (the valid prefix, even
    # for help/usage errors) so command telemetry can attribute the bucket; the executor
    # reads it into span metadata and strips it before the result reaches the shell.
    case route(cli, args, []) do
      {:leaf, leaf, path, rest} ->
        if wants_help?(rest) do
          {tag_subcommand(help_result(Help.leaf_help(cli, path, leaf)), path), bash}
        else
          dispatch_leaf(cli, leaf, path, rest, bash, stdin)
        end

      {:no_subcommand, group, path, remaining} ->
        if wants_help?(remaining) or group.on_missing_subcommand == :help do
          {tag_subcommand(help_result(Help.group_help(cli, path, group)), path), bash}
        else
          {tag_subcommand(usage_error(Help.missing_subcommand(cli, path, group)), path), bash}
        end

      {:unknown_subcommand, group, path, token} ->
        {tag_subcommand(usage_error(Help.unknown_subcommand(cli, path, group, token)), path),
         bash}
    end
  end

  @doc """
  Invoke a leaf at an explicit `path`, bypassing routing and visibility.

  Intended for handler-level unit tests: it builds the `%JustBash.CLI.Invocation{}` exactly
  as `run/4` does — merging flag defaults, collecting `extra_flags`, and running `:validate`
  — then calls the handler and returns `{result, bash}`. Prefer this (or `run/4`) over
  hand-building an `%Invocation{}`, which skips default-merging.

      {result, _bash} = JustBash.CLI.invoke(spec, ["pr", "review"], ["--report", "7"], bash)

  Raises `ArgumentError` if `path` does not resolve to a leaf.
  """
  @spec invoke(spec(), [String.t()], [String.t()], JustBash.t(), String.t()) ::
          {map(), JustBash.t()}
  def invoke(cli_or_module, path, args, bash, stdin \\ "") do
    cli = resolve(cli_or_module)

    case resolve_leaf(cli.commands, path) do
      {:ok, leaf} ->
        dispatch_leaf(cli, leaf, path, args, bash, stdin)

      :error ->
        raise ArgumentError,
              "#{cli.name}: #{Enum.join(path, " ")} is not a leaf command"
    end
  end

  # `--help`/`-h` anywhere before a `--` terminator requests help.
  defp wants_help?(tokens) do
    tokens
    |> Enum.take_while(&(&1 != "--"))
    |> Enum.any?(&(&1 in ["--help", "-h"]))
  end

  @doc """
  Return a plain-data description of the CLI's command tree.

  Useful for generating agent-facing documentation or building tab completion. Every
  leaf is listed with its full invocation `path`, resolved flag/argument specs, worked
  `examples`, and whether it accepts passthrough flags (`allow_unknown_flags`):

      JustBash.CLI.describe(cli)
      #=> %{
      #     name: "acme",
      #     doc: "Acme operations toolkit",
      #     aliases: [],
      #     commands: [
      #       %{path: ["pr", "review"], doc: "Review a pull request",
      #         flags: [%{name: :report, type: :integer, required: true, ...}], args: [],
      #         examples: [%{cmd: "acme pr review --report 42", doc: nil}],
      #         allow_unknown_flags: false},
      #       ...
      #     ]
      #   }

  Pass a `bash` as the second argument to get the catalog as a specific caller sees it:
  nodes whose `:visible?` predicate returns `false` for that `bash` are omitted, mirroring
  what routing and `--help` expose. With no `bash` (the default), every node is described.
  """
  @spec describe(spec(), JustBash.t() | nil) :: map()
  def describe(cli_or_module, bash \\ nil) do
    cli = cli_or_module |> resolve() |> maybe_prune(bash)

    %{
      name: cli.name,
      doc: cli.doc,
      aliases: cli.aliases,
      commands: describe_leaves(cli.commands, [])
    }
  end

  @doc """
  Render the CLI as a standalone document.

  Pass `format: :text` (default) for a plain-text manual, or `format: :markdown` for a
  markdown document suitable for an agent's system prompt. Pass `bash: bash` to render only
  the commands that caller can see (see `describe/2`).
  """
  @spec render_docs(spec(), keyword()) :: String.t()
  def render_docs(cli_or_module, opts \\ []) do
    cli = cli_or_module |> resolve() |> maybe_prune(Keyword.get(opts, :bash))
    Docs.render(cli, Keyword.get(opts, :format, :text))
  end

  defp maybe_prune(cli, nil), do: cli
  defp maybe_prune(cli, bash), do: prune_visible(cli, bash)

  defp describe_leaves(commands, prefix) do
    Enum.flat_map(commands, fn command ->
      path = prefix ++ [command.name]

      if Command.group?(command) do
        describe_leaves(command.commands, path)
      else
        [
          %{
            path: path,
            doc: command.doc,
            flags: describe_flags(command.flags),
            args: command.args,
            examples: command.examples,
            allow_unknown_flags: command.allow_unknown_flags
          }
        ]
      end
    end)
  end

  defp describe_flags(flags) do
    Enum.map(flags, fn {name, spec} ->
      %{
        name: name,
        type: spec[:type],
        short: spec[:short],
        long: spec[:long],
        required: spec[:required] || false,
        default: spec[:default],
        values: spec[:values],
        doc: spec[:doc]
      }
    end)
  end

  # --- routing ---

  # Walks the tree consuming leading positional tokens. `group` is either the root
  # %CLI{} or a %Command{} group; both expose `name`/`doc`/`commands`.
  defp route(group, [], path), do: {:no_subcommand, group, path, []}

  # A leading `--` before a subcommand is consumed; routing continues with the rest, so
  # `acme -- pr review` reaches `pr review` instead of erroring as a stray flag. This is
  # deliberately NOT POSIX `--` semantics (which would make everything after it positional):
  # it lets wrappers that prepend `--` still route to subcommands. `--` only acts as an
  # options/help terminator once routing reaches a leaf and hands the rest to the parser.
  # See the "`--` handling" note in the moduledoc.
  defp route(group, ["--" | rest], path), do: route(group, rest, path)

  defp route(group, ["-" <> _ | _] = remaining, path),
    do: {:no_subcommand, group, path, remaining}

  defp route(group, [token | rest], path) do
    case Enum.find(group.commands, &(&1.name == token)) do
      nil ->
        {:unknown_subcommand, group, path, token}

      %Command{run: nil} = child ->
        route(child, rest, path ++ [token])

      %Command{} = leaf ->
        {:leaf, leaf, path ++ [token], rest}
    end
  end

  # --- visibility ---

  # Prune nodes whose `:visible?` predicate rejects this caller, so they're genuinely absent
  # (not merely hidden). A group emptied by pruning is dropped too — it was only a container
  # for now-invisible children.
  defp prune_visible(%__MODULE__{} = cli, bash) do
    %{cli | commands: prune_commands(cli.commands, bash)}
  end

  defp prune_commands(commands, bash) do
    Enum.flat_map(commands, fn command ->
      cond do
        not visible?(command, bash) ->
          []

        Command.group?(command) ->
          case prune_commands(command.commands, bash) do
            [] -> []
            kept -> [%{command | commands: kept}]
          end

        true ->
          [command]
      end
    end)
  end

  defp visible?(%Command{visible?: nil}, _bash), do: true
  defp visible?(%Command{visible?: fun}, bash) when is_function(fun, 1), do: !!fun.(bash)

  # Resolve an explicit subcommand `path` to its leaf (used by `invoke/5`, which skips routing).
  defp resolve_leaf(commands, [name]) do
    case Enum.find(commands, &(&1.name == name)) do
      %Command{run: run} = leaf when not is_nil(run) -> {:ok, leaf}
      _ -> :error
    end
  end

  defp resolve_leaf(commands, [name | rest]) do
    case Enum.find(commands, &(&1.name == name)) do
      %Command{run: nil} = group -> resolve_leaf(group.commands, rest)
      _ -> :error
    end
  end

  defp resolve_leaf(_commands, []), do: :error

  # --- leaf dispatch ---

  defp dispatch_leaf(cli, %Command{} = leaf, path, rest, bash, stdin) do
    label = command_label(cli, path)

    with {:ok, flags, positional, extra} <- parse_leaf_args(leaf, rest, label),
         :ok <- validate_positionals(leaf.args, positional, label),
         invocation = build_invocation(leaf, flags, positional, extra, bash, stdin, path),
         :ok <- run_validate(leaf, invocation) do
      dispatch_run(label, leaf, path, invocation)
    else
      {:error, message} ->
        {tag_subcommand(usage_error(message <> Help.usage_line(cli, path, leaf)), path), bash}
    end
  end

  # Parse a leaf's flags, normalizing to a 4-tuple so the caller is uniform. A leaf that
  # opts into `allow_unknown_flags` collects undeclared flags into `extra`; otherwise `extra`
  # is always empty.
  defp parse_leaf_args(%Command{allow_unknown_flags: true} = leaf, rest, label) do
    ArgParser.parse(rest, leaf.flags, command: label, collect_unknown: true)
  end

  defp parse_leaf_args(%Command{} = leaf, rest, label) do
    case ArgParser.parse(rest, leaf.flags, command: label) do
      {:ok, flags, positional} -> {:ok, flags, positional, []}
      {:error, _} = err -> err
    end
  end

  defp build_invocation(_leaf, flags, positional, extra, bash, stdin, path) do
    %Invocation{
      bash: bash,
      flags: flags,
      args: positional,
      extra_flags: extra,
      stdin: stdin,
      path: path
    }
  end

  # Run a leaf's `:validate` callback before its handler. An error is shaped exactly like a
  # flag error (caught by the `with`'s else clause): exit 2 with the usage line appended.
  defp run_validate(%Command{validate: nil}, _invocation), do: :ok

  defp run_validate(%Command{validate: fun}, invocation) when is_function(fun, 1) do
    case fun.(invocation) do
      :ok -> :ok
      {:error, message} when is_binary(message) -> {:error, ensure_newline(message)}
    end
  end

  defp dispatch_run(label, %Command{} = leaf, path, invocation) do
    case leaf.run.(invocation) do
      {result, %JustBash{} = new_bash} ->
        {tag_subcommand(result, path), new_bash}

      other ->
        raise ArgumentError,
              "#{label} handler must return {result, bash}, got: #{inspect(other)}"
    end
  end

  defp ensure_newline(message) do
    if String.ends_with?(message, "\n"), do: message, else: message <> "\n"
  end

  defp validate_positionals(specs, positional, label) do
    min = Enum.count(specs, & &1.required)
    variadic? = Enum.any?(specs, & &1.variadic)
    given = length(positional)

    cond do
      given < min ->
        missing = specs |> Enum.drop(given) |> Enum.filter(& &1.required) |> Enum.map(& &1.name)
        {:error, "#{label}: missing required argument: #{Enum.join(missing, ", ")}\n"}

      not variadic? and given > length(specs) ->
        extra = Enum.drop(positional, length(specs))
        {:error, "#{label}: unexpected argument(s): #{Enum.join(extra, ", ")}\n"}

      true ->
        :ok
    end
  end

  # --- result helpers ---

  defp command_label(cli, path), do: Enum.join([cli.name | path], " ")

  defp usage_error(message), do: %{stdout: "", stderr: message, exit_code: @usage_exit}

  defp help_result(text), do: %{stdout: text, stderr: "", exit_code: 0}

  # Stash the resolved subcommand path on the result so the executor can attach it to
  # command telemetry, then strip it before the result reaches the shell (see
  # JustBash.Interpreter.Executor). Only meaningful for results that are maps.
  defp tag_subcommand(result, path) when is_map(result),
    do: Map.put(result, :__subcommand__, path)

  defp tag_subcommand(result, _path), do: result

  # --- validation helpers ---

  defp validate_name!(name, kind) do
    cond do
      not is_binary(name) or name == "" ->
        raise ArgumentError, "#{kind} name must be a non-empty string, got: #{inspect(name)}"

      String.contains?(name, " ") ->
        raise ArgumentError, "#{kind} name must not contain spaces, got: #{inspect(name)}"

      true ->
        :ok
    end
  end

  defp validate_node_kind!(name, [], nil) do
    raise ArgumentError,
          "command #{inspect(name)} must be either a group (:commands) or a leaf (:run); got neither"
  end

  defp validate_node_kind!(name, commands, run) when commands != [] and not is_nil(run) do
    raise ArgumentError,
          "command #{inspect(name)} cannot be both a group (:commands) and a leaf (:run)"
  end

  defp validate_node_kind!(_name, _commands, nil), do: :ok

  defp validate_node_kind!(name, _commands, run) when not is_function(run, 1) do
    raise ArgumentError,
          "command #{inspect(name)} :run must be a 1-arity function, got: #{inspect(run)}"
  end

  defp validate_node_kind!(_name, _commands, _run), do: :ok

  # Groups route to children and never parse their own flags/args, so reject them on a
  # group node — otherwise a misplaced flag is a silent no-op rather than a loud error.
  defp validate_leaf_only!(name, commands, flags, args)
       when commands != [] and (flags != [] or args != []) do
    raise ArgumentError,
          "command #{inspect(name)} is a group (:commands) and cannot define :flags or :args; " <>
            "move them to a leaf command"
  end

  defp validate_leaf_only!(_name, _commands, _flags, _args), do: :ok

  # Leaf-only opts are meaningless on a group (which never parses or dispatches); reject
  # them loudly rather than silently ignoring a misplaced option.
  defp reject_on_group!(name, commands, opt, value, default)
       when commands != [] and value != default do
    raise ArgumentError,
          "command #{inspect(name)} is a group (:commands) and cannot define #{inspect(opt)}; " <>
            "move it to a leaf command"
  end

  defp reject_on_group!(_name, _commands, _opt, _value, _default), do: :ok

  # `:on_missing_subcommand` only makes sense on a group/root; a leaf has no subcommands.
  defp reject_on_leaf!(name, run, opt, value, default)
       when not is_nil(run) and value != default do
    raise ArgumentError,
          "command #{inspect(name)} is a leaf (:run) and cannot define #{inspect(opt)}"
  end

  defp reject_on_leaf!(_name, _run, _opt, _value, _default), do: :ok

  defp validate_callback!(_name, _opt, nil), do: :ok
  defp validate_callback!(_name, _opt, fun) when is_function(fun, 1), do: :ok

  defp validate_callback!(name, opt, other) do
    raise ArgumentError,
          "command #{inspect(name)} #{inspect(opt)} must be a 1-arity function or nil, got: #{inspect(other)}"
  end

  defp validate_boolean!(_name, _opt, value) when is_boolean(value), do: :ok

  defp validate_boolean!(name, opt, other) do
    raise ArgumentError,
          "command #{inspect(name)} #{inspect(opt)} must be a boolean, got: #{inspect(other)}"
  end

  defp validate_on_missing!(_name, mode) when mode in [:error, :help], do: :ok

  defp validate_on_missing!(name, other) do
    raise ArgumentError,
          "#{inspect(name)} :on_missing_subcommand must be :error or :help, got: #{inspect(other)}"
  end

  # Normalize examples to `%{cmd:, doc:}` maps so `describe/1` stays JSON-clean.
  defp normalize_examples!(name, examples) when is_list(examples) do
    Enum.map(examples, &normalize_example!(name, &1))
  end

  defp normalize_examples!(name, other) do
    raise ArgumentError,
          "command #{inspect(name)} :examples must be a list, got: #{inspect(other)}"
  end

  defp normalize_example!(_name, cmd) when is_binary(cmd), do: %{cmd: cmd, doc: nil}

  defp normalize_example!(_name, %{cmd: cmd} = example) when is_binary(cmd),
    do: %{cmd: cmd, doc: Map.get(example, :doc)}

  defp normalize_example!(name, other) do
    raise ArgumentError,
          "command #{inspect(name)}: each :examples entry must be a string or a map with a " <>
            ":cmd string, got: #{inspect(other)}"
  end

  defp validate_commands!(commands) when is_list(commands) do
    Enum.each(commands, fn
      %Command{} -> :ok
      other -> raise ArgumentError, "expected a JustBash.CLI.Command, got: #{inspect(other)}"
    end)
  end

  defp validate_commands!(other) do
    raise ArgumentError,
          ":commands must be a list of JustBash.CLI.Command, got: #{inspect(other)}"
  end

  defp validate_unique_names!(commands, parent) do
    names = Enum.map(commands, & &1.name)
    dupes = names -- Enum.uniq(names)

    if dupes != [] do
      raise ArgumentError,
            "duplicate subcommand name(s) under #{inspect(parent)}: #{inspect(Enum.uniq(dupes))}"
    end
  end

  defp validate_aliases!(aliases) when is_list(aliases) do
    Enum.each(aliases, &validate_name!(&1, "alias"))
  end

  defp validate_aliases!(other) do
    raise ArgumentError, ":aliases must be a list of strings, got: #{inspect(other)}"
  end

  # Validates flag specs and fills in a default `--long` form so every flag is reachable
  # by its name (e.g. `:dry_run` -> `--dry-run`) unless an explicit `:long` is given.
  defp normalize_flags!(name, flags) when is_list(flags) do
    unless Keyword.keyword?(flags) do
      raise ArgumentError,
            "command #{inspect(name)} :flags must be a keyword list of flag specs, got: #{inspect(flags)}"
    end

    Enum.map(flags, fn {flag_name, spec} ->
      unless Keyword.keyword?(spec) do
        raise ArgumentError,
              "command #{inspect(name)} flag #{inspect(flag_name)} spec must be a keyword list, got: #{inspect(spec)}"
      end

      spec = Keyword.put_new(spec, :long, default_long(flag_name))
      validate_flag_spec!(name, flag_name, spec)
      {flag_name, spec}
    end)
  end

  defp normalize_flags!(name, flags) do
    raise ArgumentError,
          "command #{inspect(name)} :flags must be a keyword list of flag specs, got: #{inspect(flags)}"
  end

  # Build-time guards that can't drift into runtime surprises:
  #   * `--help`/`-h` are intercepted by the router before any leaf parses, so a flag that
  #     claims them could never receive its value (see the "reserved flags" note in the
  #     moduledoc).
  #   * `:required` + `:default` is contradictory — the default can never apply, since a
  #     required flag errors when omitted.
  #   * a `:default` outside `:values` would silently bypass the enum check, which only
  #     runs on provided flags.
  defp validate_flag_spec!(name, flag_name, spec) do
    cond do
      spec[:long] == "--help" or spec[:short] == "-h" ->
        reserved = if spec[:long] == "--help", do: "--help", else: "-h"

        raise ArgumentError,
              "command #{inspect(name)} flag #{inspect(flag_name)}: #{reserved} is reserved for help and cannot be used as a flag"

      spec[:required] && Keyword.has_key?(spec, :default) ->
        raise ArgumentError,
              "command #{inspect(name)} flag #{inspect(flag_name)} cannot be both :required and have a :default"

      true ->
        validate_default_in_values!(name, flag_name, spec)
    end
  end

  defp validate_default_in_values!(name, flag_name, spec) do
    with {:ok, default} <- Keyword.fetch(spec, :default),
         values when is_list(values) <- spec[:values],
         false <- default in values do
      raise ArgumentError,
            "command #{inspect(name)} flag #{inspect(flag_name)}: :default #{inspect(default)} " <>
              "is not one of :values #{inspect(values)}"
    else
      _ -> :ok
    end
  end

  defp default_long(flag_name) do
    "--" <> String.replace(Atom.to_string(flag_name), "_", "-")
  end

  defp validate_args!(name, args) when is_list(args) do
    {normalized, _acc} =
      Enum.map_reduce(args, %{variadic?: false, optional?: false}, fn arg, acc ->
        spec = normalize_arg!(name, arg)

        if acc.variadic? do
          raise ArgumentError,
                "command #{inspect(name)}: a variadic positional argument must be last"
        end

        # A required positional after an optional one is ambiguous: the handler receives a
        # flat list and can't tell which slot a single value bound to. Reject it at build
        # time, mirroring the variadic-must-be-last rule.
        if spec.required and acc.optional? do
          raise ArgumentError,
                "command #{inspect(name)}: required positional argument #{inspect(spec.name)} " <>
                  "cannot follow an optional one"
        end

        {spec,
         %{
           variadic?: acc.variadic? or spec.variadic,
           optional?: acc.optional? or not spec.required
         }}
      end)

    normalized
  end

  defp validate_args!(name, other) do
    raise ArgumentError, "command #{inspect(name)} :args must be a list, got: #{inspect(other)}"
  end

  defp normalize_arg!(_name, %{name: arg_name} = spec) when is_atom(arg_name) do
    %{
      name: arg_name,
      doc: Map.get(spec, :doc),
      required: Map.get(spec, :required, false),
      variadic: Map.get(spec, :variadic, false)
    }
  end

  defp normalize_arg!(name, other) do
    raise ArgumentError,
          "command #{inspect(name)}: each :args entry must be a map with an atom :name, got: #{inspect(other)}"
  end
end
