defmodule JustBash.Eval.Agent do
  @moduledoc """
  Tool-use agent loop that drives JustBash via the Anthropic API.

  The agent receives a task, can call a `bash` tool to execute commands,
  observes stdout/stderr/exit_code, and iterates until done.
  """

  alias JustBash.Eval.Client

  @max_turns 10

  @bash_tool %{
    name: "bash",
    description: """
    Execute a bash command in a sandboxed environment with a virtual filesystem.
    The environment persists between calls — files created in one call are available in the next.
    Available commands include: echo, cat, ls, mkdir, cp, mv, rm, touch, grep, sed, awk, jq,
    sort, uniq, head, tail, wc, tr, cut, find, printf, date, tee, xargs, dirname, basename,
    readlink, realpath, mktemp, sha256sum, shasum, chmod, chown, uname, whoami, nproc, id,
    wget, yes, eval, and more. Pipes, redirections, variables, loops, functions all work.
    """,
    input_schema: %{
      type: "object",
      properties: %{
        command: %{
          type: "string",
          description: "The bash command to execute"
        }
      },
      required: ["command"]
    }
  }

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @type result :: %{
          success: boolean(),
          turns: non_neg_integer(),
          messages: [map()],
          bash: JustBash.t(),
          final_response: String.t(),
          usage: usage()
        }

  @doc """
  Run the agent loop for a given task.

  Options:
    - `:bash` — initial JustBash state (default: `JustBash.new()`)
    - `:max_turns` — max tool-use round trips (default: #{@max_turns})
    - `:system` — system prompt override
    - `:verbose` — log tool calls and results (default: false)
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(task, opts \\ []) do
    bash = Keyword.get(opts, :bash, JustBash.new())
    max_turns = Keyword.get(opts, :max_turns, @max_turns)
    verbose = Keyword.get(opts, :verbose, false)

    commands_info = Keyword.get(opts, :commands_info)

    base_system = """
    You are a bash expert working in a sandboxed environment with a virtual in-memory filesystem. \
    Use the bash tool to execute commands and accomplish the given task.

    Important:
    - Shell state (variables, functions) does NOT persist between tool calls. Each tool call is \
    a separate invocation. Put your entire script in a single tool call when you need functions, \
    variables, or multi-step logic to work together.
    - Be efficient. Read input files if needed, then do the work and write output. Don't waste \
    calls on verification unless something went wrong.
    - The environment already has files pre-loaded. Do NOT create sample data — read what exists.
    - When done, respond with a one-line summary.\
    """

    system =
      Keyword.get_lazy(opts, :system, fn ->
        if commands_info do
          base_system <>
            "\n\nThis environment has custom commands available. " <>
            "Use `<command> --help` to learn about them.\n\n" <>
            commands_info
        else
          base_system
        end
      end)

    messages = [%{role: "user", content: task}]
    state = %{bash: bash, usage: %{input_tokens: 0, output_tokens: 0}}

    loop(messages, state, system, 0, max_turns, verbose)
  end

  defp loop(messages, state, _system, turn, max_turns, verbose) when turn >= max_turns do
    if verbose, do: log(:warn, "  max turns (#{max_turns}) reached")

    {:ok,
     %{
       success: false,
       turns: turn,
       messages: messages,
       bash: state.bash,
       final_response: "Max turns (#{max_turns}) reached",
       usage: state.usage
     }}
  end

  defp loop(messages, state, system, turn, max_turns, verbose) do
    if verbose, do: log(:info, "  turn #{turn + 1}/#{max_turns}")

    case Client.chat(messages, system: system, tools: [@bash_tool]) do
      {:ok, %{"content" => content, "stop_reason" => stop_reason, "usage" => turn_usage}} ->
        if verbose, do: log_assistant_response(content, stop_reason)

        state = accumulate_usage(state, turn_usage)
        messages = messages ++ [%{role: "assistant", content: content}]

        case stop_reason do
          "end_turn" ->
            text = extract_text(content)

            {:ok,
             %{
               success: true,
               turns: turn + 1,
               messages: messages,
               bash: state.bash,
               final_response: text,
               usage: state.usage
             }}

          "tool_use" ->
            {messages, state} = handle_tool_calls(content, messages, state, verbose)
            loop(messages, state, system, turn + 1, max_turns, verbose)

          other ->
            {:error, {:unexpected_stop_reason, other}}
        end

      {:error, reason} ->
        if verbose, do: log(:error, "  API error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_tool_calls(content, messages, state, verbose) do
    tool_uses = Enum.filter(content, fn block -> block["type"] == "tool_use" end)

    {tool_result_blocks, state} =
      Enum.reduce(tool_uses, {[], state}, fn
        %{"id" => id, "name" => "bash", "input" => %{"command" => command}},
        {acc, %{bash: bash} = st} ->
          if verbose, do: log(:cmd, "  $ #{command}")

          {result, bash} = JustBash.exec(bash, command)

          if verbose do
            if result.stdout != "", do: log(:stdout, indent(result.stdout))
            if result.stderr != "", do: log(:stderr, indent(result.stderr))
            if result.exit_code != 0, do: log(:warn, "  exit_code: #{result.exit_code}")
          end

          output =
            [
              if(result.stdout != "", do: "stdout:\n#{result.stdout}"),
              if(result.stderr != "", do: "stderr:\n#{result.stderr}"),
              "exit_code: #{result.exit_code}"
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n")

          block = %{type: "tool_result", tool_use_id: id, content: output}
          {acc ++ [block], %{st | bash: bash}}
      end)

    messages = messages ++ [%{role: "user", content: tool_result_blocks}]
    {messages, state}
  end

  defp accumulate_usage(state, %{input_tokens: input, output_tokens: output}) do
    %{
      state
      | usage: %{
          input_tokens: state.usage.input_tokens + input,
          output_tokens: state.usage.output_tokens + output
        }
    }
  end

  defp accumulate_usage(state, _), do: state

  defp extract_text(content) do
    content
    |> Enum.filter(fn block -> block["type"] == "text" end)
    |> Enum.map_join("\n", fn block -> block["text"] end)
  end

  # -- Logging helpers --

  defp log(:cmd, msg), do: IO.puts(IO.ANSI.cyan() <> msg <> IO.ANSI.reset())
  defp log(:stdout, msg), do: IO.puts(msg)
  defp log(:stderr, msg), do: IO.puts(IO.ANSI.red() <> msg <> IO.ANSI.reset())
  defp log(:warn, msg), do: IO.puts(IO.ANSI.yellow() <> msg <> IO.ANSI.reset())
  defp log(:error, msg), do: IO.puts(IO.ANSI.red() <> msg <> IO.ANSI.reset())
  defp log(:info, msg), do: IO.puts(IO.ANSI.faint() <> msg <> IO.ANSI.reset())

  defp log_assistant_response(content, stop_reason) do
    for block <- content do
      case block do
        %{"type" => "text", "text" => text} ->
          log(:info, "  [text] #{String.slice(text, 0, 200)}")

        %{"type" => "tool_use", "name" => name} ->
          log(:info, "  [tool_use] #{name} (stop: #{stop_reason})")

        _ ->
          :ok
      end
    end
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
