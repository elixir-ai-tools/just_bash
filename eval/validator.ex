defmodule JustBash.Eval.Validator do
  @moduledoc """
  Validation system for eval tasks. Each validator checks one aspect of the
  agent's output — filesystem state, tool usage patterns, or LLM-judged quality.

  `file_contains` produces one result per sub-check for precise diagnostics.
  `command_used` matches on word boundaries to avoid false positives.
  """

  alias JustBash.Eval.Client
  alias JustBash.Fs.InMemoryFs

  @type agent_result :: %{
          success: boolean(),
          turns: non_neg_integer(),
          messages: [map()],
          bash: JustBash.t(),
          final_response: String.t(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
        }

  @type check_result :: :ok | {:error, String.t()}

  @type validator ::
          {:file_contains, String.t(), [file_check()]}
          | {:command_used, String.t()}
          | {:tool_call_count, :max, pos_integer()}
          | {:llm_judge, String.t()}
          | {:custom, String.t(), (agent_result() -> check_result())}

  @type file_check ::
          {:regex, Regex.t()}
          | {:json, (term() -> check_result())}
          | {:line_count, pos_integer()}
          | {:equals, String.t()}
          | {:not_empty}

  @type validator_result :: %{
          name: String.t(),
          passed: boolean(),
          error: String.t() | nil
        }

  @doc """
  Run all validators against an agent result. Returns a list of individual results.
  `file_contains` is expanded into one result per sub-check.
  """
  @spec run_all([validator()], agent_result()) :: [validator_result()]
  def run_all(validators, agent_result) do
    Enum.flat_map(validators, &run(&1, agent_result))
  end

  @spec run(validator(), agent_result()) :: [validator_result()]
  def run(validator, result) do
    execute(validator, result)
  rescue
    e ->
      name = validator_name(validator)
      [%{name: name, passed: false, error: "CRASH: #{Exception.message(e)}"}]
  end

  # --- Validator implementations ---

  # file_contains now returns one result per sub-check for granular diagnostics
  defp execute({:file_contains, path, checks}, %{bash: bash}) do
    case InMemoryFs.read_file(bash.fs, path) do
      {:ok, content} ->
        Enum.map(checks, fn check ->
          name = file_check_name(path, check)

          case run_file_check(check, content) do
            :ok -> %{name: name, passed: true, error: nil}
            {:error, msg} -> %{name: name, passed: false, error: msg}
          end
        end)

      {:error, _} ->
        [%{name: "file:#{path}", passed: false, error: "not found"}]
    end
  end

  defp execute({:command_used, command}, %{messages: messages}) do
    name = "used:#{command}"
    commands_run = extract_commands(messages)
    pattern = Regex.compile!("(?:^|[\\s|;(&])#{Regex.escape(command)}(?:\\s|$|[|;)&])")

    result =
      if Enum.any?(commands_run, &Regex.match?(pattern, &1)) do
        %{name: name, passed: true, error: nil}
      else
        %{name: name, passed: false, error: "'#{command}' not found in any tool call"}
      end

    [result]
  end

  defp execute({:tool_call_count, :max, n}, %{turns: turns}) do
    name = "turns<=#{n}"

    result =
      if turns <= n do
        %{name: name, passed: true, error: nil}
      else
        %{name: name, passed: false, error: "used #{turns} turns, max #{n}"}
      end

    [result]
  end

  defp execute({:llm_judge, criteria}, %{messages: messages} = result) do
    name = "llm_judge"
    transcript = format_transcript(messages)

    prompt = """
    You are evaluating an AI agent's performance on a bash scripting task.

    ## Agent Transcript
    #{transcript}

    ## Agent's Final Response
    #{result.final_response}

    ## Evaluation Criteria
    #{criteria}

    Grade the agent's work. Respond with EXACTLY one of:
    - PASS: <brief reason>
    - FAIL: <brief reason>
    """

    outcome =
      case Client.chat([%{role: "user", content: prompt}], max_tokens: 256) do
        {:ok, %{"content" => content}} ->
          text = extract_text_blocks(content)

          if String.starts_with?(String.trim(text), "PASS") do
            %{name: name, passed: true, error: nil}
          else
            %{name: name, passed: false, error: String.trim(text)}
          end

        {:error, reason} ->
          %{name: name, passed: false, error: "judge API error: #{inspect(reason)}"}
      end

    [outcome]
  end

  defp execute({:custom, name, func}, result) do
    outcome =
      case func.(result) do
        :ok -> %{name: name, passed: true, error: nil}
        {:error, msg} -> %{name: name, passed: false, error: msg}
      end

    [outcome]
  end

  # --- File check helpers ---

  defp run_file_check({:regex, regex}, content) do
    if Regex.match?(regex, content) do
      :ok
    else
      {:error, "content doesn't match #{inspect(regex)}"}
    end
  end

  defp run_file_check({:json, func}, content) do
    case Jason.decode(content) do
      {:ok, data} -> func.(data)
      {:error, _} -> {:error, "invalid JSON"}
    end
  end

  defp run_file_check({:line_count, n}, content) do
    actual = content |> String.trim() |> String.split("\n") |> length()

    if actual == n do
      :ok
    else
      {:error, "expected #{n} lines, got #{actual}"}
    end
  end

  defp run_file_check({:equals, expected}, content) do
    if String.trim(content) == String.trim(expected) do
      :ok
    else
      {:error, "content mismatch"}
    end
  end

  defp run_file_check({:not_empty}, content) do
    if String.trim(content) != "" do
      :ok
    else
      {:error, "file is empty"}
    end
  end

  # --- Name helpers ---

  defp file_check_name(path, {:regex, regex}), do: "file:#{path}[#{inspect(regex)}]"
  defp file_check_name(path, {:json, _}), do: "file:#{path}[json]"
  defp file_check_name(path, {:line_count, n}), do: "file:#{path}[#{n}_lines]"
  defp file_check_name(path, {:equals, _}), do: "file:#{path}[equals]"
  defp file_check_name(path, {:not_empty}), do: "file:#{path}[not_empty]"

  defp validator_name({:file_contains, path, _}), do: "file:#{path}"
  defp validator_name({:command_used, cmd}), do: "used:#{cmd}"
  defp validator_name({:tool_call_count, :max, n}), do: "turns<=#{n}"
  defp validator_name({:llm_judge, _}), do: "llm_judge"
  defp validator_name({:custom, name, _}), do: name

  # --- Transcript helpers ---

  defp extract_commands(messages) do
    messages
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn
      %{"content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_use", "name" => "bash", "input" => %{"command" => cmd}} -> [cmd]
          _ -> []
        end)

      %{content: content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_use", "name" => "bash", "input" => %{"command" => cmd}} -> [cmd]
          _ -> []
        end)

      _ ->
        []
    end)
  end

  defp format_transcript(messages) do
    messages
    |> Enum.map(fn
      %{role: "user", content: content} when is_binary(content) ->
        "USER: #{String.slice(content, 0, 500)}"

      %{role: "assistant", content: content} when is_list(content) ->
        blocks =
          Enum.map_join(content, "\n", fn
            %{"type" => "text", "text" => text} -> "  [text] #{String.slice(text, 0, 200)}"
            %{"type" => "tool_use", "input" => %{"command" => cmd}} -> "  [bash] $ #{cmd}"
            _ -> ""
          end)

        "ASSISTANT:\n#{blocks}"

      %{role: "user", content: content} when is_list(content) ->
        blocks =
          Enum.map_join(content, "\n", fn
            %{type: "tool_result", content: out} -> "  [result] #{String.slice(out, 0, 300)}"
            _ -> ""
          end)

        "TOOL RESULTS:\n#{blocks}"

      _ ->
        ""
    end)
    |> Enum.join("\n\n")
  end

  defp extract_text_blocks(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      _ -> ""
    end)
  end

  defp extract_text_blocks(content) when is_binary(content), do: content
end
