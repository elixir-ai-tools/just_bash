defprotocol JustBash.Fs.ContentAdapter do
  @moduledoc """
  Protocol for resolving file content from different backing stores.

  Implementations must provide `resolve/1` which returns the binary content,
  and `size/1` which returns the byte size (or nil if unknown without resolving).

  ## Implementations

  - `BitString` - Identity implementation for existing binary content
  - `JustBash.Fs.Content.FunctionContent` - Content backed by a function call
  - `JustBash.Fs.Content.S3Content` - Content backed by S3 (scaffold)
  """

  @doc """
  Resolve the content to a binary.

  Returns `{:ok, binary()}` on success or `{:error, term()}` on failure.

  ## Examples

      iex> ContentAdapter.resolve("hello")
      {:ok, "hello"}

      iex> ContentAdapter.resolve(%FunctionContent{fun: fn -> "dynamic" end})
      {:ok, "dynamic"}
  """
  @spec resolve(t()) :: {:ok, binary()} | {:error, term()}
  def resolve(content)

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

  @doc "Returns the binary as-is."
  def resolve(content), do: {:ok, content}

  @doc "Returns the byte size of the binary."
  def size(content), do: byte_size(content)
end
