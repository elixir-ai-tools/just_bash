defprotocol JustBash.Fs.ContentAdapter do
  @moduledoc """
  Protocol for resolving file content from different backing stores.

  Implementations must provide `resolve/2` which returns the binary content
  and potentially updated bash state, and `size/1` which returns the byte size
  (or nil if unknown without resolving).

  ## Implementations

  - `BitString` - Identity implementation for existing binary content
  - `JustBash.Fs.Content.FunctionContent` - Content backed by a function call
  - `JustBash.Fs.Content.S3Content` - Content backed by S3 (scaffold)
  """

  @doc """
  Resolve the content to a binary, optionally accessing or modifying bash state.

  Returns `{:ok, binary(), bash}` on success or `{:error, term()}` on failure.

  The bash parameter allows content adapters to:
  - Access environment variables, current directory, etc.
  - Modify bash state (e.g., set env vars, track access)

  ## Examples

      iex> ContentAdapter.resolve("hello", bash)
      {:ok, "hello", bash}

      iex> ContentAdapter.resolve(%FunctionContent{fun: fn bash -> bash.env["USER"] end}, bash)
      {:ok, "alice", bash}

      iex> ContentAdapter.resolve(%FunctionContent{fun: fn bash ->
      ...>   new_bash = %{bash | env: Map.put(bash.env, "CALLED", "1")}
      ...>   {"content", new_bash}
      ...> end}, bash)
      {:ok, "content", updated_bash}
  """
  @spec resolve(t(), JustBash.t()) :: {:ok, binary(), JustBash.t()} | {:error, term()}
  def resolve(content, bash)

  @doc """
  Return the byte size of the content, or nil if unknown without resolving.

  For binary content, this is `byte_size/1`. For lazy content (functions, S3),
  this may return nil, indicating the size is unknown until materialized.

  ## Examples

      iex> ContentAdapter.size("hello")
      5

      iex> ContentAdapter.size(%FunctionContent{fun: fn -> "x" end})
      nil
  """
  @spec size(t()) :: non_neg_integer() | nil
  def size(content)
end

defimpl JustBash.Fs.ContentAdapter, for: BitString do
  @moduledoc """
  ContentAdapter implementation for binary strings (the default case).

  This is the identity implementation - binary content is already resolved.
  """

  @doc "Returns the binary as-is, bash state unchanged."
  def resolve(content, bash), do: {:ok, content, bash}

  @doc "Returns the byte size of the binary."
  def size(content), do: byte_size(content)
end
