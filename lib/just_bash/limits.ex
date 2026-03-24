defmodule JustBash.Limits do
  @moduledoc """
  Centralized enforcement of resource limits during script execution.

  Two error-handling patterns are used intentionally:

  - **Return tuples** (`{:ok, bash}` / `{:error, result, bash}`) for operational
    limits that fail gracefully — output bytes, environment size, execution steps.
    Callers check the return and stop or continue accordingly.

  - **Raised `ExceededError`** for hard-stop limits that must abort immediately —
    expansion word count, regex pattern/input size, glob matches, file walk entries.
    These are caught at the executor boundary (`Executor.do_execute_simple_command`).
  """

  alias JustBash.Fs.InMemoryFs
  alias JustBash.Security.Budget
  alias JustBash.Security.Policy
  alias JustBash.Security.Violation

  @output_limit_message "bash: output limit exceeded\n"

  defmodule ExceededError do
    defexception [:message, :violation]
  end

  @doc "Checks combined stdout+stderr against the output byte limit and records the violation if exceeded."
  @spec enforce_output(JustBash.t(), map()) :: {map(), JustBash.t()}
  def enforce_output(bash, result) do
    emitted_bytes = byte_size(result.stdout) + byte_size(result.stderr)
    new_total = bash.interpreter.budget.output_bytes + emitted_bytes

    if new_total > Policy.get(bash, :max_output_bytes) do
      violation = violation(:output_limit_exceeded, @output_limit_message)
      {limit_result(violation), put_violation(bash, violation)}
    else
      update_budget(bash, %{bash.interpreter.budget | output_bytes: new_total})
      |> then(&{result, &1})
    end
  end

  @doc "Writes to the virtual filesystem after checking per-file and total size limits."
  @spec write_file(JustBash.t(), String.t(), binary(), keyword()) ::
          {:ok, JustBash.t()} | {:error, atom(), JustBash.t()}
  def write_file(bash, path, content, opts \\ []) do
    normalized = InMemoryFs.normalize_path(path)

    case check_write_limits(bash, normalized, content) do
      :ok ->
        case InMemoryFs.write_file(bash.fs, normalized, content, opts) do
          {:ok, new_fs} -> {:ok, %{bash | fs: new_fs}}
          {:error, reason} -> {:error, reason, bash}
        end

      {:error, reason} ->
        violation =
          violation(write_violation_kind(reason), write_error_message(normalized, reason))

        {:error, reason, put_violation(bash, violation)}
    end
  end

  @doc "Appends content to a virtual file, checking combined size limits."
  @spec append_file(JustBash.t(), String.t(), binary()) ::
          {:ok, JustBash.t()} | {:error, atom(), JustBash.t()}
  def append_file(bash, path, content) do
    normalized = InMemoryFs.normalize_path(path)

    current_content =
      case InMemoryFs.read_file(bash.fs, normalized) do
        {:ok, existing} -> existing
        {:error, _} -> ""
      end

    write_file(bash, normalized, current_content <> content)
  end

  @doc "Returns the current sticky violation, or `nil` if none."
  @spec current_violation(JustBash.t()) :: Violation.t() | nil
  def current_violation(bash), do: bash.interpreter.budget.violation

  @doc "Returns the message string of the current violation, or `nil`."
  @spec current_violation_message(JustBash.t()) :: String.t() | nil
  def current_violation_message(bash) do
    case current_violation(bash) do
      nil -> nil
      %Violation{message: message} -> message
    end
  end

  @doc "Returns `true` if a sticky violation is present."
  @spec limit_error?(JustBash.t()) :: boolean()
  def limit_error?(bash), do: current_violation(bash) != nil

  @doc "Sets a generic `:limit_exceeded` violation with the given message."
  @spec put_limit_error(JustBash.t(), String.t()) :: JustBash.t()
  def put_limit_error(bash, message), do: put_violation(bash, violation(:limit_exceeded, message))

  @doc "Stores a `Violation` struct in the budget. Once set, it is sticky until `reset_budget/1`."
  @spec put_violation(JustBash.t(), Violation.t()) :: JustBash.t()
  def put_violation(bash, %Violation{} = violation) do
    update_budget(bash, %{bash.interpreter.budget | violation: violation})
  end

  @doc "Replaces the budget with a fresh one, clearing all counters and the sticky violation."
  @spec reset_budget(JustBash.t()) :: JustBash.t()
  def reset_budget(bash), do: update_budget(bash, Budget.new())

  @doc "Builds a failed result map (exit code 1) from a violation or plain error message."
  @spec limit_result(String.t() | Violation.t()) :: map()
  def limit_result(%Violation{message: message} = violation) do
    %{stdout: "", stderr: message, exit_code: 1, violation: violation}
  end

  def limit_result(message) when is_binary(message),
    do: %{stdout: "", stderr: message, exit_code: 1, violation: nil}

  @doc "Constructs a `Violation` struct."
  @spec violation(atom(), String.t(), map()) :: Violation.t()
  def violation(kind, message, metadata \\ %{}) do
    %Violation{kind: kind, message: message, metadata: metadata}
  end

  @doc "Raises `ExceededError` if the expansion word count exceeds the policy limit."
  @spec check_expanded_words!(JustBash.t(), non_neg_integer()) :: :ok
  def check_expanded_words!(bash, count) do
    if count > Policy.get(bash, :max_expanded_words) do
      violation = violation(:expansion_limit_exceeded, "bash: expansion limit exceeded\n")
      raise ExceededError, message: violation.message, violation: violation
    end

    :ok
  end

  @doc "Checks an HTTP response body against the byte limit before persisting."
  @spec enforce_http_body(JustBash.t(), String.t(), term()) ::
          {:ok, String.t()} | {:error, map(), JustBash.t()}
  def enforce_http_body(bash, command, body) do
    normalized_body = normalize_http_body(body)

    if byte_size(normalized_body) > Policy.get(bash, :max_http_body_bytes) do
      violation =
        violation(:http_body_limit_exceeded, "#{command}: HTTP body size limit exceeded\n")

      {:error, limit_result(violation), put_violation(bash, violation)}
    else
      {:ok, normalized_body}
    end
  end

  @doc "Raises `ExceededError` if the regex pattern exceeds the byte limit. No-op when `bash` is `nil`."
  @spec check_regex_pattern!(JustBash.t() | nil, String.t()) :: :ok
  def check_regex_pattern!(nil, _pattern), do: :ok

  def check_regex_pattern!(bash, pattern) do
    if byte_size(pattern) > Policy.get(bash, :max_regex_pattern_bytes) do
      violation =
        violation(:regex_pattern_limit_exceeded, "bash: regex pattern size limit exceeded\n")

      raise ExceededError, message: violation.message, violation: violation
    end

    :ok
  end

  @doc "Raises `ExceededError` if the regex input exceeds the byte limit. No-op when `bash` is `nil`."
  @spec check_regex_input!(JustBash.t() | nil, String.t()) :: :ok
  def check_regex_input!(nil, _input), do: :ok

  def check_regex_input!(bash, input) do
    if byte_size(input) > Policy.get(bash, :max_regex_input_bytes) do
      violation =
        violation(:regex_input_limit_exceeded, "bash: regex input size limit exceeded\n")

      raise ExceededError, message: violation.message, violation: violation
    end

    :ok
  end

  @doc "Raises `ExceededError` if the glob match count exceeds the policy limit."
  @spec check_glob_matches!(JustBash.t(), non_neg_integer()) :: :ok
  def check_glob_matches!(bash, count) do
    if count > Policy.get(bash, :max_glob_matches) do
      violation = violation(:glob_match_limit_exceeded, "bash: glob match limit exceeded\n")
      raise ExceededError, message: violation.message, violation: violation
    end

    :ok
  end

  @doc "Raises `ExceededError` if the recursive file-walk entry count exceeds the policy limit."
  @spec check_file_walk!(JustBash.t(), non_neg_integer()) :: :ok
  def check_file_walk!(bash, count) do
    if count > Policy.get(bash, :max_file_walk_entries) do
      violation = violation(:file_walk_limit_exceeded, "bash: file walk limit exceeded\n")
      raise ExceededError, message: violation.message, violation: violation
    end

    :ok
  end

  @doc "Replaces the entire environment map after checking env byte, array entry, and array byte limits."
  @spec replace_env(JustBash.t(), map()) :: {:ok, JustBash.t()} | {:error, map(), JustBash.t()}
  def replace_env(bash, env) do
    case check_env_limits(bash, env) do
      :ok ->
        {:ok, %{bash | env: env}}

      {:error, %Violation{} = violation} ->
        {:error, limit_result(violation), put_violation(bash, violation)}
    end
  end

  @doc "Sets a single environment variable, checking limits."
  @spec put_env(JustBash.t(), String.t(), String.t()) ::
          {:ok, JustBash.t()} | {:error, map(), JustBash.t()}
  def put_env(bash, name, value), do: replace_env(bash, Map.put(bash.env, name, value))

  @doc "Deletes a single environment variable, checking limits."
  @spec delete_env(JustBash.t(), String.t()) ::
          {:ok, JustBash.t()} | {:error, map(), JustBash.t()}
  def delete_env(bash, name), do: replace_env(bash, Map.delete(bash.env, name))

  @doc "Increments the execution step counter and returns an error if the limit is exceeded."
  @spec bump_step(JustBash.t()) :: {:ok, JustBash.t()} | {:error, map(), JustBash.t()}
  def bump_step(bash) do
    new_step_count = bash.interpreter.budget.step_count + 1

    if new_step_count > Policy.get(bash, :max_steps) do
      violation =
        violation(:execution_step_limit_exceeded, "bash: execution step limit exceeded\n")

      {:error, limit_result(violation), put_violation(bash, violation)}
    else
      new_budget = %{bash.interpreter.budget | step_count: new_step_count}
      {:ok, update_budget(bash, new_budget)}
    end
  end

  @doc "Formats a `bash: path: reason` error message for write failures."
  @spec write_error_message(String.t(), atom()) :: String.t()
  def write_error_message(path, :file_too_large), do: "bash: #{path}: file size limit exceeded\n"

  def write_error_message(path, :fs_quota_exceeded),
    do: "bash: #{path}: filesystem size limit exceeded\n"

  def write_error_message(path, :eisdir), do: "bash: #{path}: Is a directory\n"
  def write_error_message(path, :enoent), do: "bash: #{path}: No such file or directory\n"
  def write_error_message(path, :enotdir), do: "bash: #{path}: Not a directory\n"
  def write_error_message(path, :eacces), do: "bash: #{path}: Permission denied\n"
  def write_error_message(path, reason), do: "bash: #{path}: #{reason}\n"

  @doc "Formats a `command: path: reason` error message for command-specific write failures."
  @spec command_write_error(String.t(), String.t(), atom()) :: String.t()
  def command_write_error(command, path, :file_too_large),
    do: "#{command}: #{path}: file size limit exceeded\n"

  def command_write_error(command, path, :fs_quota_exceeded),
    do: "#{command}: #{path}: filesystem size limit exceeded\n"

  def command_write_error(command, path, :eisdir), do: "#{command}: #{path}: Is a directory\n"

  def command_write_error(command, path, :enoent),
    do: "#{command}: #{path}: No such file or directory\n"

  def command_write_error(command, path, reason), do: "#{command}: #{path}: #{reason}\n"

  defp update_budget(bash, %Budget{} = budget) do
    %{bash | interpreter: %{bash.interpreter | budget: budget}}
  end

  defp check_write_limits(bash, path, content) do
    current_size = existing_file_size(bash.fs, path)
    new_size = byte_size(content)
    total_size = total_fs_bytes(bash.fs) - current_size + new_size

    cond do
      new_size > Policy.get(bash, :max_file_bytes) -> {:error, :file_too_large}
      total_size > Policy.get(bash, :max_total_fs_bytes) -> {:error, :fs_quota_exceeded}
      true -> :ok
    end
  end

  defp existing_file_size(fs, path) do
    case InMemoryFs.read_file(fs, path) do
      {:ok, existing} -> byte_size(existing)
      {:error, _} -> 0
    end
  end

  defp total_fs_bytes(fs) do
    Enum.reduce(fs.data, 0, fn
      {_path, %{type: :file, content: content}}, acc -> acc + byte_size(content)
      _, acc -> acc
    end)
  end

  defp check_env_limits(bash, env) do
    env_bytes =
      Enum.reduce(env, 0, fn {key, value}, acc when is_binary(key) and is_binary(value) ->
        acc + byte_size(key) + byte_size(value)
      end)

    {array_entries, array_bytes} =
      Enum.reduce(env, {0, 0}, fn {key, value}, {entry_acc, byte_acc}
                                  when is_binary(key) and is_binary(value) ->
        if array_entry_key?(key) do
          {entry_acc + 1, byte_acc + byte_size(key) + byte_size(value)}
        else
          {entry_acc, byte_acc}
        end
      end)

    cond do
      env_bytes > Policy.get(bash, :max_env_bytes) ->
        {:error,
         violation(:environment_size_limit_exceeded, "bash: environment size limit exceeded\n")}

      array_entries > Policy.get(bash, :max_array_entries) ->
        {:error, violation(:array_entry_limit_exceeded, "bash: array entry limit exceeded\n")}

      array_bytes > Policy.get(bash, :max_array_bytes) ->
        {:error, violation(:array_size_limit_exceeded, "bash: array size limit exceeded\n")}

      true ->
        :ok
    end
  end

  defp array_entry_key?(key) do
    key = to_string(key)
    String.match?(key, ~r/^[^\[]+\[.+\]$/)
  end

  defp write_violation_kind(:file_too_large), do: :file_size_limit_exceeded
  defp write_violation_kind(:fs_quota_exceeded), do: :filesystem_size_limit_exceeded

  defp normalize_http_body(nil), do: ""
  defp normalize_http_body(body) when is_binary(body), do: body
  defp normalize_http_body(body), do: inspect(body)
end
