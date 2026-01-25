defmodule JustBash.Sigil do
  @moduledoc """
  Sigils for working with bash code.

  ## Usage

  Import the sigil into your module:

      import JustBash.Sigil

  Then use the `~b` sigil to execute bash code:

      # Execute bash and get the result
      result = ~b"echo hello"
      result.stdout  # "hello\\n"

      # Multi-line scripts
      result = ~b\"\"\"
      for i in 1 2 3; do
        echo $i
      done
      \"\"\"
      result.stdout  # "1\\n2\\n3\\n"

  ## Interpolation

  The `~b` sigil supports Elixir interpolation:

      name = "world"
      ~b"echo hello \#{name}"t  # "hello world"

  ## Modifiers

  - No modifier: Returns the full result map (stdout, stderr, exit_code, env)
  - `s` (stdout): Returns only stdout as a string
  - `t` (trimmed): Returns stdout with trailing newline trimmed
  - `e` (exit): Returns only the exit code
  - `x` (strict/exit): Raises if exit code is non-zero

  ## Examples

      # Full result (default)
      result = ~b"echo hello"
      result.stdout     # "hello\\n"
      result.exit_code  # 0

      # Just stdout
      ~b"echo hello"s
      # => "hello\\n"

      # Trimmed stdout (no trailing newline)
      ~b"echo hello"t
      # => "hello"

      # Exit code only
      ~b"exit 42"e
      # => 42

      # Strict - raises on non-zero exit
      ~b"echo hello"x   # => "hello\\n"
      ~b"exit 1"x       # raises!

  ## With Environment/Files

  For scripts that need initial files or environment variables,
  use `JustBash.new/1` and `JustBash.exec/2` directly:

      bash = JustBash.new(files: %{"/data.txt" => "content"}, env: %{"FOO" => "bar"})
      {result, _bash} = JustBash.exec(bash, "cat /data.txt")
  """

  @doc """
  Handles the `~b` sigil for executing bash code.

  Returns the execution result. Use modifiers to control the output format.

  ## Modifiers

  - (none): Full result map
  - `s`: stdout only
  - `t`: trimmed stdout
  - `e`: exit code only
  - `x`: strict mode - raise on non-zero exit, return stdout

  ## Examples

      iex> import JustBash.Sigil
      iex> ~b"echo hello"t
      "hello"

      iex> import JustBash.Sigil
      iex> ~b"echo -n hi"s
      "hi"
  """
  defmacro sigil_b({:<<>>, _meta, [string]}, modifiers) when is_binary(string) do
    quote do
      JustBash.Sigil.execute(unquote(string), unquote(modifiers))
    end
  end

  defmacro sigil_b({:<<>>, _meta, _parts} = ast, modifiers) do
    # Handle interpolation case
    quote do
      JustBash.Sigil.execute(unquote(ast), unquote(modifiers))
    end
  end

  @doc false
  def execute(script, modifiers) do
    bash = JustBash.new()
    {result, _bash} = JustBash.exec(bash, script)

    cond do
      ?x in modifiers ->
        if result.exit_code != 0 do
          raise "Bash script failed with exit code #{result.exit_code}: #{result.stderr}"
        end

        result.stdout

      ?e in modifiers ->
        result.exit_code

      ?t in modifiers ->
        String.trim_trailing(result.stdout, "\n")

      ?s in modifiers ->
        result.stdout

      true ->
        result
    end
  end
end
