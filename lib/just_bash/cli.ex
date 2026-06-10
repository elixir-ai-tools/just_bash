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
  defstruct name: nil, doc: nil, commands: [], aliases: []

  @type t :: %__MODULE__{
          name: String.t(),
          doc: String.t() | nil,
          commands: [Command.t()],
          aliases: [String.t()]
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
      def names, do: [spec().name | spec().aliases]

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

    %__MODULE__{
      name: name,
      doc: Keyword.get(opts, :doc),
      commands: commands,
      aliases: aliases
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

  Raises `ArgumentError` on invalid shape (e.g. both or neither of `:commands`/`:run`).
  """
  @spec command(String.t(), keyword()) :: Command.t()
  def command(name, opts \\ []) when is_binary(name) do
    validate_name!(name, "command")

    commands = Keyword.get(opts, :commands, [])
    run = Keyword.get(opts, :run)
    flags = Keyword.get(opts, :flags, [])
    args = Keyword.get(opts, :args, [])

    validate_node_kind!(name, commands, run)
    validate_leaf_only!(name, commands, flags, args)
    validate_commands!(commands)
    validate_unique_names!(commands, name)
    flags = normalize_flags!(name, flags)
    args = validate_args!(name, args)

    %Command{
      name: name,
      doc: Keyword.get(opts, :doc),
      flags: flags,
      args: args,
      commands: commands,
      run: run
    }
  end

  @doc """
  Run a CLI against raw arguments.

  Routes `args` through the command tree, parses the matched leaf's flags and
  positionals, and invokes its handler. Returns `{result, bash}` — the same shape as
  `c:JustBash.Commands.Command.execute/3`.

  Usage problems (unknown subcommand, bad flag, missing argument) return an error result
  with exit code `2` and a usage hint, rather than raising.
  """
  @spec run(t(), JustBash.t(), [String.t()], String.t()) :: {map(), JustBash.t()}
  def run(%__MODULE__{} = cli, bash, args, stdin) do
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
        if wants_help?(remaining) do
          {tag_subcommand(help_result(Help.group_help(cli, path, group)), path), bash}
        else
          {tag_subcommand(usage_error(Help.missing_subcommand(cli, path, group)), path), bash}
        end

      {:unknown_subcommand, group, path, token} ->
        {tag_subcommand(usage_error(Help.unknown_subcommand(cli, path, group, token)), path),
         bash}
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
  leaf is listed with its full invocation `path` and resolved flag/argument specs:

      JustBash.CLI.describe(cli)
      #=> %{
      #     name: "acme",
      #     doc: "Acme operations toolkit",
      #     aliases: [],
      #     commands: [
      #       %{path: ["pr", "review"], doc: "Review a pull request",
      #         flags: [%{name: :report, type: :integer, required: true, ...}], args: []},
      #       ...
      #     ]
      #   }
  """
  @spec describe(spec()) :: map()
  def describe(cli_or_module) do
    cli = resolve(cli_or_module)

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
  markdown document suitable for an agent's system prompt.
  """
  @spec render_docs(spec(), keyword()) :: String.t()
  def render_docs(cli_or_module, opts \\ []) do
    Docs.render(resolve(cli_or_module), Keyword.get(opts, :format, :text))
  end

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
            args: command.args
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

  # A `--` options terminator before a subcommand is consumed; routing continues with the
  # rest, so `acme -- pr review` reaches `pr review` instead of erroring as a stray flag.
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

  # --- leaf dispatch ---

  defp dispatch_leaf(cli, %Command{} = leaf, path, rest, bash, stdin) do
    label = command_label(cli, path)

    with {:ok, flags, positional} <- ArgParser.parse(rest, leaf.flags, command: label),
         :ok <- validate_positionals(leaf.args, positional, label) do
      invocation = %Invocation{
        bash: bash,
        flags: flags,
        args: positional,
        stdin: stdin,
        path: path
      }

      case leaf.run.(invocation) do
        {result, %JustBash{} = new_bash} ->
          {tag_subcommand(result, path), new_bash}

        other ->
          raise ArgumentError,
                "#{label} handler must return {result, bash}, got: #{inspect(other)}"
      end
    else
      {:error, message} ->
        {tag_subcommand(usage_error(message <> Help.usage_line(cli, path, leaf)), path), bash}
    end
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

      {flag_name, Keyword.put_new(spec, :long, default_long(flag_name))}
    end)
  end

  defp normalize_flags!(name, flags) do
    raise ArgumentError,
          "command #{inspect(name)} :flags must be a keyword list of flag specs, got: #{inspect(flags)}"
  end

  defp default_long(flag_name) do
    "--" <> String.replace(Atom.to_string(flag_name), "_", "-")
  end

  defp validate_args!(name, args) when is_list(args) do
    {normalized, _seen_variadic} =
      Enum.map_reduce(args, false, fn arg, variadic_seen? ->
        spec = normalize_arg!(name, arg)

        if variadic_seen? do
          raise ArgumentError,
                "command #{inspect(name)}: a variadic positional argument must be last"
        end

        {spec, spec.variadic}
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
