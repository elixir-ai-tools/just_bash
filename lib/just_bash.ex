defmodule JustBash do
  @moduledoc """
  A simulated bash environment with virtual filesystem.

  JustBash provides a sandboxed bash-like shell environment for Elixir applications.
  It's designed for AI agents and other use cases that need secure bash execution.

  ## Basic Usage

      bash = JustBash.new()
      result = JustBash.exec(bash, "echo 'Hello World'")
      IO.puts(result.stdout)  # "Hello World\\n"

  ## Features

  - In-memory virtual filesystem
  - Core bash commands (echo, cat, ls, etc.)
  - Shell features: pipes, redirections, variables
  - Control flow: if, for, while, case
  - Functions and local variables

  ## Security Model

  JustBash treats shell code as untrusted and sandboxes it in memory. Custom commands passed via
  `:commands` are trusted host-side extensions supplied by the library caller, and JustBash does
  not sandbox them or provide safety guarantees for them.

  - All execution happens in memory
  - No access to the real filesystem by default
  - No network access by default
  - Custom commands are outside the sandbox and can bypass filesystem and network restrictions
  - Execution limits to prevent infinite loops

  ## Sigil

  Use the `~b` sigil for inline bash execution:

      import JustBash.Sigil

      # Execute and get result map
      result = ~b"echo hello"
      result.stdout  # "hello\\n"

      # With modifiers
      ~b"echo hello"t  # "hello" (trimmed)
      ~b"echo hello"s  # "hello\\n" (stdout only)
      ~b"exit 42"e     # 42 (exit code)
      ~b"echo hi"x     # "hi\\n" (raises on non-zero exit)

      # With interpolation
      name = "world"
      ~b"echo hello \#{name}"t  # "hello world"
  """

  alias JustBash.Formatter
  alias JustBash.Fs
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Interpreter.Executor
  alias JustBash.Interpreter.State
  alias JustBash.Limit
  alias JustBash.Parser
  alias JustBash.Parser.Lexer

  @protected_builtin_names [
    ".",
    "break",
    "cd",
    "continue",
    "declare",
    "exit",
    "export",
    "getopts",
    "local",
    "read",
    "return",
    "set",
    "shift",
    "source",
    "trap",
    "typeset",
    "unset"
  ]

  defstruct fs: nil,
            env: %{},
            cwd: "/home/user",
            functions: %{},
            commands: %{},
            context: %{},
            exit_code: 0,
            last_exit_code: 0,
            network: %{enabled: false, allow_list: [], allow_insecure: false},
            shell_opts: %{errexit: false, nounset: false, pipefail: false},
            http_client: nil,
            databases: %{},
            max_iterations: 10_000,
            max_call_depth: 1_000,
            limits: nil,
            jq_module_paths: [],
            interpreter: nil

  @type exec_result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer(),
          env: map()
        }

  @type network_config :: %{
          enabled: boolean(),
          allow_list: [String.t()] | :all,
          allow_insecure: boolean()
        }

  @type shell_opts :: %{
          errexit: boolean(),
          nounset: boolean(),
          pipefail: boolean()
        }

  @type t :: %__MODULE__{
          fs: InMemoryFs.t(),
          env: map(),
          cwd: String.t(),
          functions: map(),
          commands: %{String.t() => module()},
          context: map(),
          exit_code: non_neg_integer(),
          last_exit_code: non_neg_integer(),
          network: network_config(),
          shell_opts: shell_opts(),
          databases: map(),
          max_iterations: pos_integer(),
          max_call_depth: pos_integer(),
          limits: Limit.t() | nil,
          jq_module_paths: [String.t()],
          interpreter: State.t()
        }

  @doc """
  Create a new JustBash environment with default configuration.

  ## Options

  - `:files` - Initial files as a map of path => content
  - `:env` - Initial environment variables
  - `:cwd` - Starting working directory (default: "/home/user")
  - `:commands` - Custom commands as a map of name => module implementing `JustBash.Commands.Command`.
    Custom commands are trusted host-side extensions supplied by the library caller. They run
    arbitrary Elixir code, are not constrained by the virtual filesystem or `:network` sandbox,
    and are outside JustBash's safety guarantees. Registration keys must be declared in the
    module's `names/0`, and aliases from `names/0` are registered automatically.
    Custom commands override regular builtins but are overridden by shell functions. Protected
    stateful builtins such as `cd` and `export` cannot be overridden.
    Dispatch order: shell functions > custom commands > builtins.
  - `:context` - Optional map of caller data for custom commands. Stored on the `JustBash` struct
    as `context` and readable inside any custom command as `bash.context`. Defaults to `%{}`.
    Not used by builtins or the interpreter; only host-defined custom commands should read it.
  - `:network` - Network configuration map with:
    - `:enabled` - Whether network access is allowed (default: false)
    - `:allow_list` - Allowed hosts/patterns. Use `:all` to allow all hosts, or a list of
      hostname patterns (e.g. `["api.example.com", "*.github.com"]`). Empty list `[]` blocks
      all requests. (default: [] = all requests blocked when enabled)
    - `:allow_insecure` - Whether plain HTTP is permitted. When false (default), only `https://`
      URLs are allowed. Scripts cannot override this — it is a caller-level control.
  - `:http_client` - Module implementing the HTTP client behaviour (default: uses Req)
  - `:max_iterations` - Maximum iterations for `while`/`until` loops before they are
    forcibly stopped. Prevents runaway loops from untrusted scripts (default: 10_000)
  - `:max_call_depth` - Maximum shell function call depth before recursion is
    forcibly stopped. Prevents unbounded recursion from consuming all available
    memory (default: 1_000)
  - `:limits` - Resource limits for production safety. Accepts a preset atom
    (`:default`, `:strict`, `:relaxed`), a keyword list of overrides, or `false`
    to disable. Default: `:default`. See `JustBash.Limit` for available keys.
  - `:jq_module_paths` - List of virtual filesystem paths to search for `jq` modules
    when using `import`/`include` directives (default: [])

  ## Examples

      bash = JustBash.new()
      bash = JustBash.new(files: %{"/data/file.txt" => "content"})
      bash = JustBash.new(env: %{"MY_VAR" => "value"}, cwd: "/app")
      bash = JustBash.new(commands: %{"python" => MyPythonCommand})
      bash = JustBash.new(network: %{enabled: true})
      bash = JustBash.new(network: %{enabled: true, allow_list: ["api.example.com", "*.github.com"]})

      # Custom HTTP client for testing:
      bash = JustBash.new(network: %{enabled: true}, http_client: MyTestHttpClient)

      # Pass data to custom commands via bash.context:
      bash = JustBash.new(context: %{user_id: 42}, commands: %{"my_cmd" => MyCommand})
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    files = Keyword.get(opts, :files, %{})
    env = Keyword.get(opts, :env, %{})
    cwd = Keyword.get(opts, :cwd, "/home/user")
    commands = opts |> Keyword.get(:commands, %{}) |> normalize_commands!()
    network = Keyword.get(opts, :network, %{})
    http_client = Keyword.get(opts, :http_client)
    max_iterations = Keyword.get(opts, :max_iterations, 10_000)
    max_call_depth = Keyword.get(opts, :max_call_depth, 1_000)
    limits = opts |> Keyword.get(:limits, :default) |> Limit.new()
    jq_module_paths = Keyword.get(opts, :jq_module_paths, [])
    context = opts |> Keyword.get(:context, %{}) |> validate_context!()

    default_env = %{
      "HOME" => cwd,
      "PATH" => "/bin:/usr/bin",
      "IFS" => " \t\n",
      "PWD" => cwd,
      "OLDPWD" => cwd,
      "?" => "0",
      "#" => "0",
      # Simulated PID for the sandboxed shell
      "$" => Integer.to_string(:erlang.unique_integer([:positive]) |> rem(100_000))
    }

    %__MODULE__{
      fs: init_filesystem(files),
      env: Map.merge(default_env, env),
      cwd: cwd,
      functions: %{},
      commands: commands,
      context: context,
      exit_code: 0,
      last_exit_code: 0,
      network: Map.merge(%{enabled: false, allow_list: [], allow_insecure: false}, network),
      http_client: http_client,
      max_iterations: max_iterations,
      max_call_depth: max_call_depth,
      limits: limits,
      jq_module_paths: jq_module_paths,
      interpreter: State.new()
    }
  end

  defp validate_context!(context) when is_map(context), do: context

  defp validate_context!(other) do
    raise ArgumentError, "expected :context to be a map, got: #{inspect(other)}"
  end

  defp normalize_commands!(commands) when is_map(commands) do
    Enum.reduce(commands, %{}, fn {name, module}, acc ->
      names = validate_command_registration!(name, module)

      Enum.reduce(names, acc, fn alias_name, current_acc ->
        if alias_name in @protected_builtin_names do
          raise ArgumentError,
                "custom command #{inspect(module)} cannot override protected builtin #{inspect(alias_name)}"
        end

        case Map.get(current_acc, alias_name) do
          nil ->
            Map.put(current_acc, alias_name, module)

          ^module ->
            current_acc

          other_module ->
            raise ArgumentError,
                  "custom command name #{inspect(alias_name)} is already registered to #{inspect(other_module)}"
        end
      end)
    end)
  end

  defp normalize_commands!(commands) do
    raise ArgumentError, "expected :commands to be a map, got: #{inspect(commands)}"
  end

  # Validates the registration and returns the list of names from the module.
  # Called once per registration entry to avoid double-calling names/0.
  defp validate_command_registration!(name, module) when is_binary(name) and is_atom(module) do
    if name == "" do
      raise ArgumentError,
            "custom command name must not be empty"
    end

    if name in @protected_builtin_names do
      raise ArgumentError,
            "custom commands cannot override protected builtin #{inspect(name)}"
    end

    Code.ensure_loaded(module)

    unless function_exported?(module, :execute, 3) and function_exported?(module, :names, 0) do
      raise ArgumentError,
            "custom command #{inspect(module)} must export execute/3 and names/0"
    end

    names = module.names()

    unless is_list(names) and names != [] and Enum.all?(names, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError,
            "custom command #{inspect(module)} must return a non-empty list of non-empty names from names/0"
    end

    unless name in names do
      raise ArgumentError,
            "custom command #{inspect(module)} was registered as #{inspect(name)} but names/0 returns #{inspect(names)}"
    end

    names
  end

  defp validate_command_registration!(name, module) do
    raise ArgumentError,
          "invalid custom command registration #{inspect(name)} => #{inspect(module)}; expected a string name and module"
  end

  defp init_filesystem(files) do
    default_dirs = [
      "/home",
      "/home/user",
      "/bin",
      "/usr",
      "/usr/bin",
      "/tmp"
    ]

    fs = InMemoryFs.new()

    fs =
      Enum.reduce(default_dirs, fs, fn path, acc_fs ->
        case InMemoryFs.mkdir(acc_fs, path, recursive: true) do
          {:ok, new_fs} -> new_fs
          {:error, :eexist} -> acc_fs
          _ -> acc_fs
        end
      end)

    Enum.reduce(files, fs, fn {path, content}, acc_fs ->
      {:ok, new_fs} = InMemoryFs.write_file(acc_fs, path, content)
      new_fs
    end)
  end

  @doc """
  Execute a bash command in the environment.

  Returns a tuple of {result, updated_bash} where result contains
  stdout, stderr, exit_code, and the final env.

  ## Examples

      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "echo hello")
      result.stdout  # "hello\\n"
      result.exit_code  # 0

      {result, _bash} = JustBash.exec(bash, "cat nonexistent")
      result.stderr  # "cat: nonexistent: No such file or directory\\n"
      result.exit_code  # 1
  """
  @spec exec(t(), String.t()) :: {exec_result(), t()}
  def exec(bash, command) when is_binary(command) do
    # Reset counters only for top-level exec (not nested eval/source)
    bash =
      if bash.interpreter.exec_depth == 0 do
        %{bash | interpreter: State.reset_counters(bash.interpreter)}
      else
        bash
      end

    JustBash.Telemetry.session_span(self(), fn ->
      case Parser.parse(command) do
        {:ok, ast} ->
          {result, final_bash} = Executor.execute_script(bash, ast)
          # Execute EXIT trap if set
          {result, final_bash} = execute_exit_trap(result, final_bash)

          {{result, final_bash},
           %{
             status: :ok,
             exit_code: result.exit_code,
             bytes_in: byte_size(command),
             bytes_out: byte_size(result.stdout) + byte_size(result.stderr)
           }}

        {:error, error} ->
          stderr = "bash: syntax error: #{error.message}\n"

          result =
            {%{stdout: "", stderr: stderr, exit_code: 2, env: bash.env}, bash}

          {result,
           %{
             status: :error,
             exit_code: 2,
             bytes_in: byte_size(command),
             bytes_out: byte_size(stderr)
           }}
      end
    end)
  end

  defp execute_exit_trap(result, bash) do
    traps = Map.get(bash, :traps, %{})

    case Map.get(traps, "EXIT") do
      nil ->
        {result, bash}

      trap_cmd ->
        # Execute the trap command
        case Parser.parse(trap_cmd) do
          {:ok, ast} ->
            {trap_result, trap_bash} = Executor.execute_script(bash, ast)

            # Combine output, keep original exit code
            combined_result = %{
              result
              | stdout: result.stdout <> trap_result.stdout,
                stderr: result.stderr <> trap_result.stderr
            }

            {combined_result, trap_bash}

          {:error, _} ->
            {result, bash}
        end
    end
  end

  @typedoc "Execution statistics from the most recent `exec/2` call."
  @type stats :: %{
          steps: non_neg_integer(),
          output_bytes: non_neg_integer(),
          max_exec_depth: non_neg_integer()
        }

  @doc """
  Returns execution statistics from the most recent `exec/2` call.

  Useful for observing computational cost without enforcing limits —
  for example, as a reward signal in reinforcement learning to prefer
  simpler programs.

  Counters reset at the start of each top-level `exec/2` call, so
  stats always reflect the most recent execution.

  ## Examples

      bash = JustBash.new()
      {_result, bash} = JustBash.exec(bash, "for i in 1 2 3; do echo $i; done")
      JustBash.stats(bash)
      #=> %{steps: 12, output_bytes: 6, max_exec_depth: 1}
  """
  @spec stats(t()) :: stats()
  def stats(%__MODULE__{interpreter: interp}) do
    %{
      steps: interp.step_count,
      output_bytes: interp.output_bytes,
      max_exec_depth: interp.max_exec_depth
    }
  end

  @doc """
  Execute a bash command, raising on parse errors.

  ## Examples

      bash = JustBash.new()
      {result, _bash} = JustBash.exec!(bash, "echo hello")
  """
  @spec exec!(t(), String.t()) :: {exec_result(), t()}
  def exec!(bash, command) do
    JustBash.Telemetry.session_span(self(), fn ->
      case Parser.parse(command) do
        {:ok, ast} ->
          {result, final_bash} = Executor.execute_script(bash, ast)

          {{result, final_bash},
           %{
             status: :ok,
             exit_code: result.exit_code,
             bytes_in: byte_size(command),
             bytes_out: byte_size(result.stdout) + byte_size(result.stderr)
           }}

        {:error, error} ->
          raise "Parse error: #{error.message}"
      end
    end)
  end

  @doc """
  Parse a bash script and return the AST.

  Useful for debugging or analyzing scripts without executing them.

  ## Examples

      {:ok, ast} = JustBash.parse("echo hello")
      {:error, error} = JustBash.parse("echo 'unterminated")
  """
  @spec parse(String.t()) :: {:ok, JustBash.AST.Script.t()} | {:error, Parser.ParseError.t()}
  def parse(input), do: Parser.parse(input)

  @doc """
  Tokenize a bash script and return the tokens.

  Useful for debugging the lexer.

  ## Examples

      {:ok, tokens} = JustBash.tokenize("echo hello")
      # [%Token{type: :name, value: "echo", ...}, %Token{type: :name, value: "hello", ...}, ...]
  """
  @spec tokenize(String.t()) :: {:ok, [Lexer.Token.t()]} | {:error, Lexer.Error.t()}
  def tokenize(input), do: Lexer.tokenize(input)

  @doc """
  Tokenize a bash command string, raising on error.
  """
  @spec tokenize!(String.t()) :: [Lexer.Token.t()]
  def tokenize!(input), do: Lexer.tokenize!(input)

  @doc """
  Format a bash script into a consistent, readable format.

  Parses the input script and outputs it with consistent formatting:
  - Consistent indentation for control structures
  - Normalized whitespace
  - Proper line breaks

  ## Options

  - `:indent` - Indentation string (default: "  " - two spaces)

  ## Examples

      JustBash.format("if true;then echo yes;fi")
      # {:ok, "if true; then\\n  echo yes\\nfi"}

      JustBash.format("echo   hello    world")
      # {:ok, "echo hello world"}

      JustBash.format("for i in 1 2 3;do echo $i;done")
      # {:ok, "for i in 1 2 3; do\\n  echo $i\\ndone"}
  """
  @spec format(String.t(), keyword()) :: {:ok, String.t()} | {:error, Parser.ParseError.t()}
  def format(input, opts \\ []) when is_binary(input) do
    case Parser.parse(input) do
      {:ok, ast} -> {:ok, Formatter.format(ast, opts)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Format a bash script, raising on parse errors.

  ## Examples

      JustBash.format!("echo hello")
      # "echo hello"
  """
  @spec format!(String.t(), keyword()) :: String.t()
  def format!(input, opts \\ []) when is_binary(input) do
    case format(input, opts) do
      {:ok, formatted} -> formatted
      {:error, error} -> raise "Parse error: #{error.message}"
    end
  end

  @doc """
  Execute a bash script from a path in the virtual filesystem.

  Reads the script from the sandbox's virtual filesystem and executes it.
  The script must exist in `bash.fs` — no real filesystem access occurs.

  ## Examples

      bash = JustBash.new(files: %{"/script.sh" => "echo hello"})
      {result, bash} = JustBash.exec_file(bash, "/script.sh")

  """
  @spec exec_file(t(), String.t()) :: {exec_result(), t()}
  def exec_file(%JustBash{} = bash, path) do
    resolved = Fs.resolve_path(bash.cwd, path)

    case Fs.read_file(bash.fs, resolved) do
      {:ok, script} ->
        exec(bash, script)

      {:error, _reason} ->
        error_msg = "#{path}: No such file or directory\n"
        {%{stdout: "", stderr: error_msg, exit_code: 1, env: bash.env}, bash}
    end
  end
end
