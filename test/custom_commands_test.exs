defmodule JustBash.CustomCommandsTest do
  use ExUnit.Case, async: true

  alias JustBash.Fs

  # --- Test command modules ---

  defmodule Greet do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["greet"]

    @impl true
    def execute(bash, args, _stdin) do
      name = Enum.join(args, " ")
      {%{stdout: "Hello, #{name}!\n", stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule Upcase do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["upcase"]

    @impl true
    def execute(bash, _args, stdin) do
      {%{stdout: String.upcase(stdin), stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule CustomEcho do
    @doc "Overrides builtin echo with a prefix"
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["echo"]

    @impl true
    def execute(bash, args, _stdin) do
      output = "CUSTOM: " <> Enum.join(args, " ") <> "\n"
      {%{stdout: output, stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule AliasGreet do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["greet", "hello"]

    @impl true
    def execute(bash, args, _stdin) do
      name = Enum.join(args, " ")
      {%{stdout: "Hello, #{name}!\n", stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule FileWriter do
    @doc "A command that writes to the filesystem"
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["writeout"]

    @impl true
    def execute(bash, args, stdin) do
      case args do
        [path] ->
          resolved = Fs.resolve_path(bash.cwd, path)

          case Fs.write_file(bash.fs, resolved, stdin) do
            {:ok, new_fs} ->
              {%{stdout: "", stderr: "", exit_code: 0}, %{bash | fs: new_fs}}

            {:error, reason} ->
              {%{stdout: "", stderr: "writeout: #{reason}\n", exit_code: 1}, bash}
          end

        _ ->
          {%{stdout: "", stderr: "writeout: expected 1 argument\n", exit_code: 1}, bash}
      end
    end
  end

  defmodule Failing do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["fail"]

    @impl true
    def execute(bash, args, _stdin) do
      code =
        case args do
          [n] -> String.to_integer(n)
          _ -> 1
        end

      {%{stdout: "", stderr: "fail: intentional failure\n", exit_code: code}, bash}
    end
  end

  defmodule Crashy do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["crashy"]

    @impl true
    def execute(_bash, _args, _stdin) do
      raise "boom"
    end
  end

  defmodule Throwy do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["throwy"]

    @impl true
    def execute(_bash, _args, _stdin) do
      throw(:kaboom)
    end
  end

  defmodule AnotherGreet do
    @doc "A second module that also claims the name 'greet' — conflicts with AliasGreet"
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["greet", "hi"]

    @impl true
    def execute(bash, args, _stdin) do
      name = Enum.join(args, " ")
      {%{stdout: "Hey, #{name}!\n", stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule ControlFlowInjector do
    @doc "A malicious command that tries to inject __return__ into the result"
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["inject"]

    @impl true
    def execute(bash, _args, _stdin) do
      result = %{stdout: "injected\n", stderr: "", exit_code: 0, __return__: 0}
      {result, bash}
    end
  end

  defmodule MissingExecute do
    def names, do: ["missing"]
  end

  defmodule CustomCd do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["cd"]

    @impl true
    def execute(bash, _args, _stdin) do
      {%{stdout: "not allowed\n", stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule EnvReader do
    @doc "A command that reads environment variables"
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["readenv"]

    @impl true
    def execute(bash, args, _stdin) do
      output = Enum.map_join(args, "\n", fn var -> "#{var}=#{Map.get(bash.env, var, "")}" end)

      output = if output != "", do: output <> "\n", else: ""
      {%{stdout: output, stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule ContextDumper do
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["ctxdump"]

    @impl true
    def execute(bash, _args, _stdin) do
      {%{stdout: inspect(bash.context) <> "\n", stderr: "", exit_code: 0}, bash}
    end
  end

  defmodule Counter do
    @doc "A command that reads a file, increments the number in it, and writes it back"
    @behaviour JustBash.Commands.Command

    @impl true
    def names, do: ["counter"]

    @impl true
    def execute(bash, args, _stdin) do
      path =
        case args do
          [p] -> p
          _ -> "/counter"
        end

      resolved = Fs.resolve_path(bash.cwd, path)

      current =
        case Fs.read_file(bash.fs, resolved) do
          {:ok, content} -> String.trim(content) |> String.to_integer()
          {:error, :enoent} -> 0
        end

      next = current + 1
      {:ok, new_fs} = Fs.write_file(bash.fs, resolved, Integer.to_string(next))
      {%{stdout: "#{next}\n", stderr: "", exit_code: 0}, %{bash | fs: new_fs}}
    end
  end

  # ===== TESTS =====

  describe "basic custom command execution" do
    test "custom command is found and executed" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "greet World")
      assert result.stdout == "Hello, World!\n"
      assert result.exit_code == 0
    end

    test "custom command receives multiple arguments" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "greet Brave New World")
      assert result.stdout == "Hello, Brave New World!\n"
    end

    test "custom command with no arguments" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "greet")
      assert result.stdout == "Hello, !\n"
    end

    test "custom command returns non-zero exit code" do
      bash = JustBash.new(commands: %{"fail" => Failing})
      {result, _} = JustBash.exec(bash, "fail 42")
      assert result.exit_code == 42
      assert result.stderr == "fail: intentional failure\n"
    end

    test "custom command aliases declared in names/0 are executable" do
      bash = JustBash.new(commands: %{"greet" => AliasGreet})
      {result, _} = JustBash.exec(bash, "hello World")
      assert result.stdout == "Hello, World!\n"
    end

    test "custom command crashes (raise) are converted into shell errors" do
      bash = JustBash.new(commands: %{"crashy" => Crashy})
      {result, _} = JustBash.exec(bash, "crashy")
      assert result.exit_code == 1
      assert result.stderr =~ "custom command crashed"
      assert result.stderr =~ "crashy"
    end

    test "custom command crashes (throw) are converted into shell errors" do
      bash = JustBash.new(commands: %{"throwy" => Throwy})
      {result, _} = JustBash.exec(bash, "throwy")
      assert result.exit_code == 1
      assert result.stderr =~ "throwy"
      assert result.stderr =~ "throw"
    end
  end

  describe "custom command context" do
    test "custom command receives bash.context from JustBash.new" do
      ctx = %{"api_key" => "secret", greeting: "hello"}

      bash =
        JustBash.new(
          context: ctx,
          commands: %{"ctxdump" => ContextDumper}
        )

      {result, _} = JustBash.exec(bash, "ctxdump")
      assert String.trim(result.stdout) == inspect(ctx)
      assert result.exit_code == 0
    end

    test "custom command sees default empty context when :context omitted" do
      bash = JustBash.new(commands: %{"ctxdump" => ContextDumper})
      {result, _} = JustBash.exec(bash, "ctxdump")
      assert String.trim(result.stdout) == inspect(%{})
      assert result.exit_code == 0
    end
  end

  describe "command registration validation" do
    test "commands option must be a map" do
      assert_raise ArgumentError, ~r/expected :commands to be a map/, fn ->
        JustBash.new(commands: nil)
      end
    end

    test "command module must implement execute/3" do
      assert_raise ArgumentError, ~r/must export execute\/3 and names\/0/, fn ->
        JustBash.new(commands: %{"missing" => MissingExecute})
      end
    end

    test "registration key must be declared in names/0" do
      assert_raise ArgumentError, ~r/registered as "different" but names\/0 returns/, fn ->
        JustBash.new(commands: %{"different" => AliasGreet})
      end
    end

    test "protected builtins cannot be overridden" do
      assert_raise ArgumentError, ~r/cannot override protected builtin "cd"/, fn ->
        JustBash.new(commands: %{"cd" => CustomCd})
      end
    end

    test "conflicting alias between two modules raises" do
      assert_raise ArgumentError, ~r/already registered to/, fn ->
        JustBash.new(commands: %{"greet" => AliasGreet, "hi" => AnotherGreet})
      end
    end

    test "empty string command name is rejected" do
      defmodule EmptyName do
        @behaviour JustBash.Commands.Command
        @impl true
        def names, do: [""]
        @impl true
        def execute(bash, _args, _stdin),
          do: {%{stdout: "", stderr: "", exit_code: 0}, bash}
      end

      assert_raise ArgumentError, ~r/empty/, fn ->
        JustBash.new(commands: %{"" => EmptyName})
      end
    end
  end

  describe "custom command overrides builtin" do
    test "custom echo overrides builtin echo" do
      bash = JustBash.new(commands: %{"echo" => CustomEcho})
      {result, _} = JustBash.exec(bash, "echo hello")
      assert result.stdout == "CUSTOM: hello\n"
    end

    test "non-overridden builtins still work alongside custom commands" do
      bash = JustBash.new(commands: %{"echo" => CustomEcho})
      {result, _} = JustBash.exec(bash, "printf '%s' hello")
      assert result.stdout == "hello"
    end

    test "builtin cat still works when custom commands don't override it" do
      bash =
        JustBash.new(
          commands: %{"greet" => Greet},
          files: %{"/test.txt" => "content"}
        )

      {result, _} = JustBash.exec(bash, "cat /test.txt")
      assert result.stdout == "content"
    end
  end

  describe "shell functions override custom commands" do
    test "shell function takes priority over custom command" do
      bash = JustBash.new(commands: %{"greet" => Greet})

      {result, _} =
        JustBash.exec(bash, """
        greet() { echo "FUNC: $1"; }
        greet World
        """)

      assert result.stdout == "FUNC: World\n"
    end

    test "custom command is used when no shell function is defined" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "greet World")
      assert result.stdout == "Hello, World!\n"
    end
  end

  describe "pipelines" do
    test "custom command as pipeline source" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "greet World | tr '!' '?'")
      assert result.stdout == "Hello, World?\n"
    end

    test "custom command as pipeline sink (receives stdin)" do
      bash = JustBash.new(commands: %{"upcase" => Upcase})
      {result, _} = JustBash.exec(bash, "echo hello | upcase")
      assert result.stdout == "HELLO\n"
    end

    test "custom command in middle of pipeline" do
      bash = JustBash.new(commands: %{"upcase" => Upcase})
      {result, _} = JustBash.exec(bash, "echo hello world | upcase | tr ' ' '-'")
      assert result.stdout == "HELLO-WORLD\n"
    end

    test "two custom commands piped together" do
      bash = JustBash.new(commands: %{"greet" => Greet, "upcase" => Upcase})
      {result, _} = JustBash.exec(bash, "greet world | upcase")
      assert result.stdout == "HELLO, WORLD!\n"
    end
  end

  describe "stdin from heredocs and here-strings" do
    test "custom command receives heredoc stdin" do
      bash = JustBash.new(commands: %{"upcase" => Upcase})

      {result, _} =
        JustBash.exec(bash, """
        upcase <<EOF
        hello world
        EOF
        """)

      assert result.stdout == "HELLO WORLD\n"
    end

    test "custom command receives here-string stdin" do
      bash = JustBash.new(commands: %{"upcase" => Upcase})
      {result, _} = JustBash.exec(bash, "upcase <<< 'hello world'")
      assert result.stdout == "HELLO WORLD\n"
    end
  end

  describe "filesystem interaction" do
    test "custom command can write to filesystem" do
      bash = JustBash.new(commands: %{"writeout" => FileWriter})
      {_result, bash} = JustBash.exec(bash, "echo hello | writeout /output.txt")
      {result, _} = JustBash.exec(bash, "cat /output.txt")
      assert result.stdout == "hello\n"
    end

    test "custom command can read from filesystem" do
      bash =
        JustBash.new(
          commands: %{"upcase" => Upcase},
          files: %{"/data.txt" => "hello"}
        )

      {result, _} = JustBash.exec(bash, "cat /data.txt | upcase")
      assert result.stdout == "HELLO"
    end

    test "custom command fs changes persist across commands" do
      bash = JustBash.new(commands: %{"counter" => Counter})
      {result1, bash} = JustBash.exec(bash, "counter /count.txt")
      assert result1.stdout == "1\n"
      {result2, bash} = JustBash.exec(bash, "counter /count.txt")
      assert result2.stdout == "2\n"
      {result3, _bash} = JustBash.exec(bash, "counter /count.txt")
      assert result3.stdout == "3\n"
    end

    test "custom command fs changes visible to subsequent commands in same script" do
      bash = JustBash.new(commands: %{"writeout" => FileWriter})

      {result, _} =
        JustBash.exec(bash, """
        echo "data" | writeout /file.txt
        cat /file.txt
        """)

      assert result.stdout == "data\n"
    end
  end

  describe "redirections" do
    test "stdout redirection from custom command" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {_result, bash} = JustBash.exec(bash, "greet World > /out.txt")
      {result, _} = JustBash.exec(bash, "cat /out.txt")
      assert result.stdout == "Hello, World!\n"
    end

    test "stderr redirection from custom command" do
      bash = JustBash.new(commands: %{"fail" => Failing})
      {_result, bash} = JustBash.exec(bash, "fail 2>/err.txt")
      {result, _} = JustBash.exec(bash, "cat /err.txt")
      assert result.stdout == "fail: intentional failure\n"
    end

    test "stdin redirection to custom command" do
      bash =
        JustBash.new(
          commands: %{"upcase" => Upcase},
          files: %{"/input.txt" => "hello world"}
        )

      {result, _} = JustBash.exec(bash, "upcase < /input.txt")
      assert result.stdout == "HELLO WORLD"
    end

    test "append redirection from custom command" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {_result, bash} = JustBash.exec(bash, "greet Alice > /out.txt")
      {_result, bash} = JustBash.exec(bash, "greet Bob >> /out.txt")
      {result, _} = JustBash.exec(bash, "cat /out.txt")
      assert result.stdout == "Hello, Alice!\nHello, Bob!\n"
    end
  end

  describe "multiple custom commands" do
    test "multiple custom commands all accessible" do
      bash =
        JustBash.new(
          commands: %{
            "greet" => Greet,
            "upcase" => Upcase,
            "fail" => Failing
          }
        )

      {r1, _} = JustBash.exec(bash, "greet World")
      assert r1.stdout == "Hello, World!\n"
      {r2, _} = JustBash.exec(bash, "echo hello | upcase")
      assert r2.stdout == "HELLO\n"
      {r3, _} = JustBash.exec(bash, "fail")
      assert r3.exit_code == 1
    end

    test "custom commands interact through filesystem" do
      bash =
        JustBash.new(
          commands: %{
            "writeout" => FileWriter,
            "upcase" => Upcase
          }
        )

      {result, _} =
        JustBash.exec(bash, """
        echo "hello world" | writeout /data.txt
        cat /data.txt | upcase
        """)

      assert result.stdout == "HELLO WORLD\n"
    end
  end

  describe "environment variables and expansion" do
    test "custom command receives expanded arguments" do
      bash =
        JustBash.new(
          commands: %{"greet" => Greet},
          env: %{"NAME" => "World"}
        )

      {result, _} = JustBash.exec(bash, "greet $NAME")
      assert result.stdout == "Hello, World!\n"
    end

    test "custom command can read environment variables from bash struct" do
      bash =
        JustBash.new(
          commands: %{"readenv" => EnvReader},
          env: %{"FOO" => "bar", "BAZ" => "qux"}
        )

      {result, _} = JustBash.exec(bash, "readenv FOO BAZ")
      assert result.stdout == "FOO=bar\nBAZ=qux\n"
    end

    test "command substitution with custom command" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "echo \"Got: $(greet World)\"")
      assert result.stdout == "Got: Hello, World!\n"
    end

    test "custom command in arithmetic test" do
      bash = JustBash.new(commands: %{"fail" => Failing})

      {result, _} =
        JustBash.exec(bash, """
        if fail; then
          echo yes
        else
          echo no
        fi
        """)

      assert result.stdout == "no\n"
    end
  end

  describe "control flow" do
    test "custom command as if condition" do
      bash = JustBash.new(commands: %{"greet" => Greet, "fail" => Failing})

      {result, _} =
        JustBash.exec(bash, """
        if greet test > /dev/null; then
          echo "greet succeeded"
        fi
        """)

      assert result.stdout == "greet succeeded\n"

      {result, _} =
        JustBash.exec(bash, """
        if fail; then
          echo "should not reach"
        else
          echo "fail failed"
        fi
        """)

      assert result.stdout == "fail failed\n"
    end

    test "custom command in for loop" do
      bash = JustBash.new(commands: %{"greet" => Greet})

      {result, _} =
        JustBash.exec(bash, """
        for name in Alice Bob Charlie; do
          greet $name
        done
        """)

      assert result.stdout == "Hello, Alice!\nHello, Bob!\nHello, Charlie!\n"
    end

    test "custom command in while loop" do
      bash =
        JustBash.new(
          commands: %{"counter" => Counter},
          files: %{"/count.txt" => "0"}
        )

      {result, _} =
        JustBash.exec(bash, """
        while [ "$(cat /count.txt)" -lt 3 ]; do
          counter /count.txt > /dev/null
        done
        cat /count.txt
        """)

      assert result.stdout == "3"
    end

    test "custom command with && and || operators" do
      bash = JustBash.new(commands: %{"greet" => Greet, "fail" => Failing})
      {result, _} = JustBash.exec(bash, "greet World > /dev/null && echo success")
      assert result.stdout == "success\n"

      {result, _} = JustBash.exec(bash, "fail || echo recovered")
      assert result.stdout == "recovered\n"
    end
  end

  describe "edge cases" do
    test "empty commands map is valid" do
      bash = JustBash.new(commands: %{})
      {result, _} = JustBash.exec(bash, "echo hello")
      assert result.stdout == "hello\n"
    end

    test "unknown command still returns command not found" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "nonexistent")
      assert result.exit_code == 127
      assert result.stderr =~ "command not found"
    end

    test "custom command state changes propagate through bash struct" do
      bash = JustBash.new(commands: %{"writeout" => FileWriter})
      {_, bash} = JustBash.exec(bash, "echo 'first' | writeout /f1.txt")
      {_, bash} = JustBash.exec(bash, "echo 'second' | writeout /f2.txt")
      {result, _} = JustBash.exec(bash, "cat /f1.txt /f2.txt")
      assert result.stdout == "first\nsecond\n"
    end

    test "custom command with quoted arguments" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "greet 'Big World'")
      assert result.stdout == "Hello, Big World!\n"
    end

    test "custom command with glob expansion in arguments" do
      bash =
        JustBash.new(
          commands: %{"greet" => Greet},
          files: %{"/data/a.txt" => "", "/data/b.txt" => ""}
        )

      {result, _} = JustBash.exec(bash, "greet /data/*.txt")
      # Glob should expand to the file paths
      assert result.stdout =~ "/data/"
      assert result.stdout =~ "a.txt"
      assert result.stdout =~ "b.txt"
    end

    test "which shows custom commands even when PATH is empty" do
      bash = JustBash.new(commands: %{"greet" => Greet}, env: %{"PATH" => ""})
      {result, _} = JustBash.exec(bash, "which greet")
      assert result.exit_code == 0
      assert result.stdout == "greet\n"
    end

    test "which -a lists custom command (no builtin overlap)" do
      bash = JustBash.new(commands: %{"greet" => Greet})
      {result, _} = JustBash.exec(bash, "which -a greet")
      assert result.exit_code == 0
      assert result.stdout == "greet\n"
    end

    test "custom command cannot inject control flow signals into result" do
      bash = JustBash.new(commands: %{"inject" => ControlFlowInjector})

      # If __return__ leaked through, the second echo would not run
      {result, _} =
        JustBash.exec(bash, """
        myfunc() {
          inject
          echo "after inject"
        }
        myfunc
        """)

      assert result.stdout =~ "injected"
      assert result.stdout =~ "after inject"
    end

    test "which -a lists both custom command and builtin info" do
      bash = JustBash.new(commands: %{"echo" => CustomEcho})
      {result, _} = JustBash.exec(bash, "which -a echo")
      assert result.exit_code == 0
      lines = String.split(result.stdout, "\n", trim: true)
      # Custom command appears first, then the builtin description
      assert "echo" in lines
      assert Enum.any?(lines, &String.contains?(&1, "shell built-in command"))
      assert length(lines) >= 2
    end
  end
end
