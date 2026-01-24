defmodule JustBash.Interpreter.Executor.Redirection do
  @moduledoc """
  Handles file redirections for bash commands.

  Supports:
  - Output redirection: `>`, `>>`
  - Error redirection: `2>`, `2>>`
  - Input redirection: `<`
  - Here-strings: `<<<`
  - Combined redirection: `&>`
  - Stream duplication: `>&`, `2>&1`, `1>&2`
  - /dev/null handling
  """

  alias JustBash.AST
  alias JustBash.Fs.InMemoryFs
  alias JustBash.Interpreter.Expansion

  @type result :: %{stdout: String.t(), stderr: String.t(), exit_code: non_neg_integer()}
  @type redir_type ::
          :stdout_dev_null
          | :stderr_dev_null
          | :stdout_write
          | :stdout_append
          | :stderr_write
          | :stderr_append
          | :stdout_to_stderr
          | :stderr_to_stdout
          | :combined_write
          | :stdin_read
          | :noop

  @doc """
  Apply a list of redirections to the result.
  """
  @spec apply_redirections(result(), JustBash.t(), [AST.Redirection.t()]) ::
          {result(), JustBash.t()}
  def apply_redirections(result, bash, []) do
    {result, bash}
  end

  def apply_redirections(result, bash, [redir | rest]) do
    {result, bash} = apply_redirection(result, bash, redir)
    apply_redirections(result, bash, rest)
  end

  @doc """
  Extract heredoc or here-string content as stdin.
  Returns `{stdin_content, non_heredoc_redirections}`.
  """
  @spec extract_heredoc_stdin(JustBash.t(), [AST.Redirection.t()]) ::
          {String.t() | nil, [AST.Redirection.t()]}
  def extract_heredoc_stdin(bash, redirections) do
    stdin_content = extract_stdin_content(bash, redirections)

    non_heredoc_redirs =
      Enum.reject(redirections, fn
        %AST.Redirection{operator: :<<<} -> true
        %AST.Redirection{operator: :"<<", target: %AST.HereDoc{}} -> true
        %AST.Redirection{operator: :<} -> true
        _ -> false
      end)

    {stdin_content, non_heredoc_redirs}
  end

  # --- Private Functions ---

  defp apply_redirection(result, bash, %AST.Redirection{
         fd: fd,
         operator: operator,
         target: target
       }) do
    target_path = Expansion.expand_redirect_target(bash, target)
    resolved = InMemoryFs.resolve_path(bash.cwd, target_path)
    redir_type = classify_redirection(fd, operator, target_path)
    apply_classified_redirection(redir_type, result, bash, resolved)
  end

  @spec classify_redirection(non_neg_integer(), atom(), String.t()) :: redir_type()
  defp classify_redirection(2, :>, "/dev/null"), do: :stderr_dev_null
  defp classify_redirection(2, :">>", "/dev/null"), do: :stderr_dev_null
  defp classify_redirection(_fd, _operator, "/dev/null"), do: :stdout_dev_null
  defp classify_redirection(2, :>, _target), do: :stderr_write
  defp classify_redirection(2, :">>", _target), do: :stderr_append
  defp classify_redirection(_fd, :>, _target), do: :stdout_write
  defp classify_redirection(_fd, :">>", _target), do: :stdout_append
  defp classify_redirection(1, :">&", "2"), do: :stdout_to_stderr
  defp classify_redirection(2, :">&", "1"), do: :stderr_to_stdout
  defp classify_redirection(_fd, :"&>", _target), do: :combined_write
  defp classify_redirection(_fd, :<, _target), do: :stdin_read
  defp classify_redirection(_fd, _operator, _target), do: :noop

  defp apply_classified_redirection(:stdout_dev_null, result, bash, _resolved) do
    {%{result | stdout: ""}, bash}
  end

  defp apply_classified_redirection(:stderr_dev_null, result, bash, _resolved) do
    {%{result | stderr: ""}, bash}
  end

  defp apply_classified_redirection(:stderr_write, result, bash, resolved) do
    write_to_file(bash, resolved, result.stderr, result, :stderr)
  end

  defp apply_classified_redirection(:stderr_append, result, bash, resolved) do
    append_to_file(bash, resolved, result.stderr, result, :stderr)
  end

  defp apply_classified_redirection(:stdout_write, result, bash, resolved) do
    write_to_file(bash, resolved, result.stdout, result, :stdout)
  end

  defp apply_classified_redirection(:stdout_append, result, bash, resolved) do
    append_to_file(bash, resolved, result.stdout, result, :stdout)
  end

  defp apply_classified_redirection(:stdout_to_stderr, result, bash, _resolved) do
    {%{result | stderr: result.stderr <> result.stdout, stdout: ""}, bash}
  end

  defp apply_classified_redirection(:stderr_to_stdout, result, bash, _resolved) do
    {%{result | stdout: result.stdout <> result.stderr, stderr: ""}, bash}
  end

  defp apply_classified_redirection(:combined_write, result, bash, resolved) do
    combined = result.stdout <> result.stderr
    write_combined_to_file(bash, resolved, combined, result)
  end

  defp apply_classified_redirection(:stdin_read, result, bash, _resolved) do
    # Input redirection is handled separately via extract_heredoc_stdin
    {result, bash}
  end

  defp apply_classified_redirection(:noop, result, bash, _resolved) do
    {result, bash}
  end

  defp write_to_file(bash, path, content, result, stream) do
    case InMemoryFs.write_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        updated_result = clear_stream(result, stream)
        {updated_result, %{bash | fs: new_fs}}

      {:error, reason} ->
        error_msg = format_redirection_error(path, reason)
        {%{result | stderr: result.stderr <> error_msg, exit_code: 1}, bash}
    end
  end

  defp append_to_file(bash, path, content, result, stream) do
    current_content =
      case InMemoryFs.read_file(bash.fs, path) do
        {:ok, existing} -> existing
        {:error, _} -> ""
      end

    case InMemoryFs.write_file(bash.fs, path, current_content <> content) do
      {:ok, new_fs} ->
        updated_result = clear_stream(result, stream)
        {updated_result, %{bash | fs: new_fs}}

      {:error, reason} ->
        error_msg = format_redirection_error(path, reason)
        {%{result | stderr: result.stderr <> error_msg, exit_code: 1}, bash}
    end
  end

  defp write_combined_to_file(bash, path, content, result) do
    case InMemoryFs.write_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        {%{result | stdout: "", stderr: ""}, %{bash | fs: new_fs}}

      {:error, reason} ->
        error_msg = format_redirection_error(path, reason)
        {%{result | stderr: error_msg, exit_code: 1}, bash}
    end
  end

  defp clear_stream(result, :stdout), do: %{result | stdout: ""}
  defp clear_stream(result, :stderr), do: %{result | stderr: ""}

  defp format_redirection_error(path, :eisdir), do: "bash: #{path}: Is a directory\n"

  # --- Stdin Content Extraction ---

  # Here-string: <<< "string"
  defp extract_stdin_content(bash, [%AST.Redirection{operator: :<<<, target: target} | _]) do
    content = Expansion.expand_redirect_target(bash, target)
    content <> "\n"
  end

  # Input redirection: < file
  defp extract_stdin_content(bash, [%AST.Redirection{operator: :<, target: target} | _]) do
    path = Expansion.expand_redirect_target(bash, target)
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  # Heredoc with content
  defp extract_stdin_content(bash, [%AST.Redirection{target: %AST.HereDoc{content: content}} | _])
       when not is_nil(content) do
    Expansion.expand_word_parts_simple(bash, content.parts)
  end

  # Heredoc without content (empty)
  defp extract_stdin_content(_bash, [%AST.Redirection{target: %AST.HereDoc{}} | _]) do
    ""
  end

  defp extract_stdin_content(_bash, [_ | rest]) do
    extract_stdin_content(nil, rest)
  end

  defp extract_stdin_content(_bash, []) do
    nil
  end
end
