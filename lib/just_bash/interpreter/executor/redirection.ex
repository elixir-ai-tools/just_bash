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
  alias JustBash.FS
  alias JustBash.Interpreter.Expansion
  alias JustBash.Limit

  @type result :: %{stdout: String.t(), stderr: String.t(), exit_code: non_neg_integer()}

  @typedoc """
  A redirection whose target has already been expanded, resolved, and opened
  by `preflight/2`.

  The path is `nil` for redirections that touch no file (`/dev/null`, stream
  duplication, `<`). Carrying the resolved path forward is what keeps a
  target containing a command substitution from being expanded a second
  time when the output is finally written.
  """
  @type prepared :: {redir_type(), String.t() | nil}

  @type redir_type ::
          :stdout_dev_null
          | :stderr_dev_null
          | :combined_dev_null
          | :stdout_write
          | :stdout_append
          | :stderr_write
          | :stderr_append
          | :stdout_to_stderr
          | :stderr_to_stdout
          | :combined_write
          | :combined_append
          | :stdin_read
          | :close_fd
          | :noop

  @doc """
  Expand, resolve, and open every redirection target, left to right, *before*
  the command body runs.

  bash opens redirect targets before forking the command, so a target it
  cannot open means the command never runs — none of its side effects happen.
  On `{:error, result, bash}` the caller must return `result` without
  executing the body; on `{:ok, prepared, bash}` it runs the body and hands
  `prepared` to `apply_redirections/3`.

  Opening follows the `open/2` flags bash uses: `>`, `2>` and `&>` create or
  truncate (`O_CREAT | O_TRUNC`), `>>` and `&>>` create only if missing
  (`O_CREAT | O_APPEND`). Redirections that touch no file — `/dev/null`,
  `>&`, `<` — are classified and passed through untouched.

  Targets to the left of a failing one are still created or truncated, and
  targets to its right are never expanded, so a command substitution in one
  of them does not run. Both match bash.
  """
  @spec preflight(JustBash.t(), [AST.Redirection.t()]) ::
          {:ok, [prepared()], JustBash.t()} | {:error, result(), JustBash.t()}
  def preflight(bash, redirections), do: do_preflight(bash, redirections, [])

  @doc """
  Apply preflighted redirections to the result, writing each stream to the
  target `preflight/2` already opened.
  """
  @spec apply_redirections(result(), JustBash.t(), [prepared()]) ::
          {result(), JustBash.t()}
  def apply_redirections(result, bash, []) do
    {result, bash}
  end

  def apply_redirections(result, bash, [{redir_type, resolved} | rest]) do
    {result, bash} = apply_classified_redirection(redir_type, result, bash, resolved)
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

  defp do_preflight(bash, [], prepared), do: {:ok, Enum.reverse(prepared), bash}

  defp do_preflight(bash, [redirection | rest], prepared) do
    %AST.Redirection{fd: fd, operator: operator, target: target} = redirection

    target_path = Expansion.expand_redirect_target(bash, target)
    redir_type = classify_redirection(fd, operator, target_path)
    resolved = FS.resolve_path(bash.cwd, target_path)

    case open_target(bash, redir_type, resolved) do
      {:ok, bash} ->
        do_preflight(bash, rest, [{redir_type, resolved} | prepared])

      {:error, error, bash} ->
        {:error, open_failed(resolved, error), bash}
    end
  end

  # The shell reports the failure itself and the command produces nothing:
  # its stdout and stderr were bound for a file that was never opened.
  defp open_failed(path, error) do
    %{stdout: "", stderr: "bash: #{path}: #{FS.strerror(error)}\n", exit_code: 1}
  end

  defp open_target(bash, redir_type, path) do
    case open_mode(redir_type) do
      :truncate -> create_or_truncate(bash, path)
      :append -> open_for_append(bash, path)
      :none -> {:ok, bash}
    end
  end

  @spec open_mode(redir_type()) :: :truncate | :append | :none
  defp open_mode(:stdout_write), do: :truncate
  defp open_mode(:stderr_write), do: :truncate
  defp open_mode(:combined_write), do: :truncate
  defp open_mode(:stdout_append), do: :append
  defp open_mode(:stderr_append), do: :append
  defp open_mode(:combined_append), do: :append
  defp open_mode(_redir_type), do: :none

  defp create_or_truncate(bash, path) do
    case FS.write_file(bash.fs, path, "") do
      {:ok, fs} -> {:ok, %{bash | fs: fs}}
      {:error, %VFS.Error{} = error} -> {:error, error, bash}
    end
  end

  # `O_APPEND` keeps what is already there, so an existing target is left
  # alone — writing it back would bump its mtime for nothing. Everything a
  # later append would reject still has to be rejected here: a directory, or
  # a path running through a regular file.
  defp open_for_append(bash, path) do
    case FS.stat(bash.fs, path) do
      {:ok, %VFS.Stat{type: :directory}, fs} ->
        {:error, VFS.Error.new(:eisdir, path: path), %{bash | fs: fs}}

      {:ok, %VFS.Stat{}, fs} ->
        {:ok, %{bash | fs: fs}}

      {:error, %VFS.Error{kind: :enoent}} ->
        create_or_truncate(bash, path)

      {:error, %VFS.Error{} = error} ->
        {:error, error, bash}
    end
  end

  @spec classify_redirection(non_neg_integer(), atom(), String.t()) :: redir_type()
  # Combined redirection &> must be checked before /dev/null catch-all
  defp classify_redirection(_fd, :"&>", "/dev/null"), do: :combined_dev_null
  defp classify_redirection(_fd, :"&>>", "/dev/null"), do: :combined_dev_null
  defp classify_redirection(_fd, :"&>", _target), do: :combined_write
  defp classify_redirection(_fd, :"&>>", _target), do: :combined_append
  defp classify_redirection(2, :>, "/dev/null"), do: :stderr_dev_null
  defp classify_redirection(2, :">>", "/dev/null"), do: :stderr_dev_null
  defp classify_redirection(_fd, _operator, "/dev/null"), do: :stdout_dev_null
  defp classify_redirection(2, :>, _target), do: :stderr_write
  defp classify_redirection(2, :">>", _target), do: :stderr_append
  defp classify_redirection(_fd, :>, _target), do: :stdout_write
  defp classify_redirection(_fd, :">>", _target), do: :stdout_append
  # >&2 without explicit fd defaults to 1>&2 (stdout to stderr)
  defp classify_redirection(fd, :">&", "2") when fd in [nil, 1], do: :stdout_to_stderr
  defp classify_redirection(fd, :">&", "1") when fd in [nil, 2], do: :stderr_to_stdout
  defp classify_redirection(_fd, :">&", "-"), do: :close_fd
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

  defp apply_classified_redirection(:combined_append, result, bash, resolved) do
    combined = result.stdout <> result.stderr
    append_combined_to_file(bash, resolved, combined, result)
  end

  defp apply_classified_redirection(:combined_dev_null, result, bash, _resolved) do
    {%{result | stdout: "", stderr: ""}, bash}
  end

  defp apply_classified_redirection(:stdin_read, result, bash, _resolved) do
    # Input redirection is handled separately via extract_heredoc_stdin
    {result, bash}
  end

  defp apply_classified_redirection(:close_fd, result, bash, _resolved) do
    # Closing a file descriptor - just clear the output
    # In a real shell this would close the fd, but here we just discard
    {result, bash}
  end

  defp apply_classified_redirection(:noop, result, bash, _resolved) do
    {result, bash}
  end

  # A command that produced nothing leaves the target exactly as `preflight/2`
  # opened it — truncated for `>`, untouched for `>>` — so the four clauses
  # below have nothing to write. Skipping the write is not just an
  # optimization: appending zero bytes is not a write at all, and bash leaves
  # the target's mtime alone after `true >> file`.
  defp write_to_file(bash, _path, "", result, stream), do: {clear_stream(result, stream), bash}

  defp write_to_file(bash, path, content, result, stream) do
    Limit.check_file_size!(bash, content)

    case FS.write_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        updated_result = clear_stream(result, stream)
        {updated_result, %{bash | fs: new_fs}}

      {:error, error} ->
        {redirect_failed(result, stream, path, error), bash}
    end
  end

  defp append_to_file(bash, _path, "", result, stream), do: {clear_stream(result, stream), bash}

  defp append_to_file(bash, path, content, result, stream) do
    bash = check_append_size!(bash, path, content)

    case FS.append_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        updated_result = clear_stream(result, stream)
        {updated_result, %{bash | fs: new_fs}}

      {:error, error} ->
        {redirect_failed(result, stream, path, error), bash}
    end
  end

  defp write_combined_to_file(bash, _path, "", result) do
    {%{result | stdout: "", stderr: ""}, bash}
  end

  defp write_combined_to_file(bash, path, content, result) do
    Limit.check_file_size!(bash, content)

    case FS.write_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        {%{result | stdout: "", stderr: ""}, %{bash | fs: new_fs}}

      {:error, error} ->
        {result |> clear_stream(:stdout) |> redirect_failed(:stderr, path, error), bash}
    end
  end

  defp append_combined_to_file(bash, _path, "", result) do
    {%{result | stdout: "", stderr: ""}, bash}
  end

  defp append_combined_to_file(bash, path, content, result) do
    bash = check_append_size!(bash, path, content)

    case FS.append_file(bash.fs, path, content) do
      {:ok, new_fs} ->
        {%{result | stdout: "", stderr: ""}, %{bash | fs: new_fs}}

      {:error, error} ->
        {result |> clear_stream(:stdout) |> redirect_failed(:stderr, path, error), bash}
    end
  end

  # The size limit applies to the resulting file, so account for what is
  # already there before appending.
  defp check_append_size!(bash, path, content) do
    {existing_size, bash} =
      case FS.stat(bash.fs, path) do
        {:ok, %VFS.Stat{size: size}, fs} -> {size, %{bash | fs: fs}}
        {:error, _} -> {0, bash}
      end

    Limit.check_file_size!(bash, existing_size + byte_size(content))
    bash
  end

  defp clear_stream(result, :stdout), do: %{result | stdout: ""}
  defp clear_stream(result, :stderr), do: %{result | stderr: ""}

  # Failures the open in `preflight/2` cannot predict, because they depend on
  # what the command produced — a write past `Limit`'s file-size cap, or a
  # target that stopped being writable while the body ran. The command has
  # already run, so all that is left is to suppress the stream that was bound
  # for the file and report the failure the way bash does.
  defp redirect_failed(result, stream, path, error) do
    cleared = clear_stream(result, stream)
    error_msg = "bash: #{path}: #{FS.strerror(error)}\n"
    %{cleared | stderr: cleared.stderr <> error_msg, exit_code: 1}
  end

  # --- Stdin Content Extraction ---

  # Here-string: <<< "string"
  defp extract_stdin_content(bash, [%AST.Redirection{operator: :<<<, target: target} | _]) do
    content = Expansion.expand_redirect_target(bash, target)
    content <> "\n"
  end

  # Input redirection: < file
  defp extract_stdin_content(bash, [%AST.Redirection{operator: :<, target: target} | _]) do
    path = Expansion.expand_redirect_target(bash, target)
    resolved = FS.resolve_path(bash.cwd, path)

    case FS.read_file(bash.fs, resolved) do
      {:ok, content, _fs} -> content
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

  defp extract_stdin_content(bash, [_ | rest]) do
    extract_stdin_content(bash, rest)
  end

  defp extract_stdin_content(_bash, []) do
    nil
  end
end
