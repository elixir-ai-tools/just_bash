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

  - All execution happens in memory
  - No access to the real filesystem by default
  - No network access by default
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
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Interpreter.Executor
  alias JustBash.Parser
  alias JustBash.Parser.Lexer

  defstruct fs: nil,
            env: %{},
            cwd: "/home/user",
            functions: %{},
            exit_code: 0,
            last_exit_code: 0,
            network: %{enabled: false, allow_list: []},
            shell_opts: %{errexit: false, nounset: false, pipefail: false},
            http_client: nil,
            databases: %{}

  @type exec_result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer(),
          env: map()
        }

  @type network_config :: %{
          enabled: boolean(),
          allow_list: [String.t()]
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
          exit_code: non_neg_integer(),
          last_exit_code: non_neg_integer(),
          network: network_config(),
          shell_opts: shell_opts(),
          databases: map()
        }

  @doc """
  Create a new JustBash environment with default configuration.

  ## Options

  - `:files` - Initial files as a map of path => content
  - `:env` - Initial environment variables
  - `:cwd` - Starting working directory (default: "/home/user")
  - `:network` - Network configuration map with:
    - `:enabled` - Whether network access is allowed (default: false)
    - `:allow_list` - List of allowed hosts/patterns (default: [] = all allowed when enabled)
  - `:http_client` - Module implementing the HTTP client behaviour (default: uses Req)

  ## Examples

      bash = JustBash.new()
      bash = JustBash.new(files: %{"/data/file.txt" => "content"})
      bash = JustBash.new(env: %{"MY_VAR" => "value"}, cwd: "/app")
      bash = JustBash.new(network: %{enabled: true})
      bash = JustBash.new(network: %{enabled: true, allow_list: ["api.example.com", "*.github.com"]})

      # Custom HTTP client for testing:
      bash = JustBash.new(network: %{enabled: true}, http_client: MyTestHttpClient)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    files = Keyword.get(opts, :files, %{})
    env = Keyword.get(opts, :env, %{})
    cwd = Keyword.get(opts, :cwd, "/home/user")
    network = Keyword.get(opts, :network, %{enabled: false, allow_list: []})
    http_client = Keyword.get(opts, :http_client)

    default_env = %{
      "HOME" => cwd,
      "PATH" => "/bin:/usr/bin",
      "IFS" => " \t\n",
      "PWD" => cwd,
      "OLDPWD" => cwd,
      "?" => "0",
      # Simulated PID for the sandboxed shell
      "$" => Integer.to_string(:erlang.unique_integer([:positive]) |> rem(100_000))
    }

    %__MODULE__{
      fs: init_filesystem(files),
      env: Map.merge(default_env, env),
      cwd: cwd,
      functions: %{},
      exit_code: 0,
      last_exit_code: 0,
      network: Map.merge(%{enabled: false, allow_list: []}, network),
      http_client: http_client
    }
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

    Enum.reduce(files, fs, fn
      {path, content}, acc_fs when is_binary(content) ->
        {:ok, new_fs} = InMemoryFs.write_file(acc_fs, path, content)
        new_fs

      {path, content}, acc_fs when is_struct(content) ->
        {:ok, new_fs} = InMemoryFs.write_file(acc_fs, path, content)
        new_fs

      {path, content}, acc_fs when is_function(content, 0) ->
        fc = JustBash.Fs.Content.FunctionContent.new(content)
        {:ok, new_fs} = InMemoryFs.write_file(acc_fs, path, fc)
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
    case Parser.parse(command) do
      {:ok, ast} ->
        {result, final_bash} = Executor.execute_script(bash, ast)
        # Execute EXIT trap if set
        execute_exit_trap(result, final_bash)

      {:error, error} ->
        {%{
           stdout: "",
           stderr: "bash: syntax error: #{error.message}\n",
           exit_code: 2,
           env: bash.env
         }, bash}
    end
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

  @doc """
  Execute a bash command, raising on parse errors.

  ## Examples

      bash = JustBash.new()
      {result, _bash} = JustBash.exec!(bash, "echo hello")
  """
  @spec exec!(t(), String.t()) :: {exec_result(), t()}
  def exec!(bash, command) do
    case Parser.parse(command) do
      {:ok, ast} ->
        Executor.execute_script(bash, ast)

      {:error, error} ->
        raise "Parse error: #{error.message}"
    end
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

      tokens = JustBash.tokenize("echo hello")
      # [%Token{type: :name, value: "echo", ...}, %Token{type: :name, value: "hello", ...}, ...]
  """
  @spec tokenize(String.t()) :: [Lexer.Token.t()]
  def tokenize(input), do: Lexer.tokenize(input)

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
  Execute a bash script from a file on the real filesystem.

  Reads the script from disk and executes it in the JustBash sandbox.
  This is useful for development and testing scripts stored in real files.

  ## Options

  All options from `new/1` are supported, plus:
  - `:print` - Print stdout/stderr to console (default: true)

  ## Examples

      # Run a script file
      JustBash.exec_file("~/scripts/test.sh")

      # Run with initial files in the sandbox
      JustBash.exec_file("script.sh", files: %{"/data/input.txt" => "hello"})

      # Run with network enabled
      JustBash.exec_file("fetch_data.sh", network: %{enabled: true})

      # Get result without printing
      {result, bash} = JustBash.exec_file("script.sh", print: false)

  ## CLI Usage

      mix run -e 'JustBash.exec_file("script.sh")'
  """
  @spec exec_file(String.t(), keyword()) :: {exec_result(), t()}
  def exec_file(path, opts \\ []) do
    {print, opts} = Keyword.pop(opts, :print, true)
    expanded_path = Path.expand(path)

    case File.read(expanded_path) do
      {:ok, script} ->
        bash = new(opts)
        {result, bash} = exec(bash, script)

        if print do
          if result.stdout != "", do: IO.write(result.stdout)
          if result.stderr != "", do: IO.write(:stderr, result.stderr)

          if result.exit_code != 0 do
            IO.puts(:stderr, "\n[exit code: #{result.exit_code}]")
          end
        end

        {result, bash}

      {:error, reason} ->
        error_msg = "Cannot read file '#{path}': #{:file.format_error(reason)}\n"

        if print do
          IO.write(:stderr, error_msg)
        end

        {%{stdout: "", stderr: error_msg, exit_code: 1, env: %{}}, new(opts)}
    end
  end

  @doc """
  Execute a bash script file, raising on file read errors.

  ## Examples

      {result, bash} = JustBash.exec_file!("script.sh")
  """
  @spec exec_file!(String.t(), keyword()) :: {exec_result(), t()}
  def exec_file!(path, opts \\ []) do
    expanded_path = Path.expand(path)
    script = File.read!(expanded_path)
    bash = new(opts)
    exec(bash, script)
  end

  @doc """
  Materialize all lazy file content (functions, S3 refs) into binary strings.

  Call this before execution if you want to ensure all content is resolved
  and avoid repeated function calls during execution.

  ## Returns

  - `{:ok, updated_bash}` - bash with all files materialized
  - `{:error, term()}` - content resolution error

  ## Examples

      bash = JustBash.new(files: %{
        "/dynamic.txt" => fn -> expensive_computation() end
      })

      # Materialize once before multiple executions
      {:ok, bash} = JustBash.materialize_files(bash)

      {result1, bash} = JustBash.exec(bash, "cat /dynamic.txt")
      {result2, bash} = JustBash.exec(bash, "cat /dynamic.txt")
      # Function only called once during materialize
  """
  @spec materialize_files(t()) :: {:ok, t()} | {:error, term()}
  def materialize_files(%__MODULE__{fs: fs} = bash) do
    case InMemoryFs.materialize_all(fs) do
      {:ok, new_fs} -> {:ok, %{bash | fs: new_fs}}
      {:error, _} = err -> err
    end
  end
end
