defmodule JustBash.Fs.Content.S3Content do
  @moduledoc """
  File content backed by an S3 object (scaffold implementation).

  Requires a client module implementing the `get_object/2` callback
  for actual S3 access. This keeps the JustBash library free of AWS
  dependencies while demonstrating the extension pattern.

  ## Usage

      # Define your S3 client
      defmodule MyS3Client do
        @behaviour JustBash.Fs.Content.S3Content

        @impl true
        def get_object(bucket, key) do
          # Use your preferred AWS SDK
          case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
            {:ok, %{body: body}} -> {:ok, body}
            {:error, reason} -> {:error, reason}
          end
        end
      end

      # Use in JustBash
      bash = JustBash.new(files: %{
        "/data.txt" => S3Content.new(
          bucket: "my-bucket",
          key: "data.txt",
          client: MyS3Client
        )
      })
  """

  @type t :: %__MODULE__{
          bucket: String.t(),
          key: String.t(),
          client: module(),
          size: non_neg_integer() | nil,
          cached_content: binary() | nil
        }

  @enforce_keys [:bucket, :key, :client]
  defstruct [:bucket, :key, :client, :size, :cached_content]

  @doc """
  Callback for S3 client implementations.

  Should fetch the object from S3 and return the binary content.
  """
  @callback get_object(bucket :: String.t(), key :: String.t()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Create a new S3-backed content source.

  ## Options

  - `:bucket` - S3 bucket name (required)
  - `:key` - S3 object key (required)
  - `:client` - Module implementing the S3Content callback (required)
  - `:size` - Known object size in bytes (optional, for stat without fetching)

  ## Examples

      iex> S3Content.new(bucket: "my-bucket", key: "file.txt", client: MyS3Client)
      %S3Content{bucket: "my-bucket", key: "file.txt", client: MyS3Client}

      iex> S3Content.new(bucket: "my-bucket", key: "file.txt", client: MyS3Client, size: 1024)
      %S3Content{bucket: "my-bucket", key: "file.txt", client: MyS3Client, size: 1024}
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      bucket: Keyword.fetch!(opts, :bucket),
      key: Keyword.fetch!(opts, :key),
      client: Keyword.fetch!(opts, :client),
      size: Keyword.get(opts, :size)
    }
  end

  @doc """
  Materialize the content by fetching from S3 and caching the result.

  Returns `{:ok, binary, updated_struct}` with the cached content.

  ## Examples

      iex> s3 = S3Content.new(bucket: "b", key: "k", client: MyS3Client)
      iex> {:ok, content, cached_s3} = S3Content.materialize(s3)
      iex> cached_s3.cached_content
      "fetched content"
  """
  @spec materialize(t()) :: {:ok, binary(), t()} | {:error, term()}
  def materialize(%__MODULE__{cached_content: content} = s3) when not is_nil(content) do
    {:ok, content, s3}
  end

  def materialize(%__MODULE__{client: client, bucket: bucket, key: key} = s3) do
    case client.get_object(bucket, key) do
      {:ok, content} when is_binary(content) ->
        {:ok, content, %{s3 | cached_content: content, size: byte_size(content)}}

      {:error, _} = err ->
        err
    end
  end
end

defimpl JustBash.Fs.ContentAdapter, for: JustBash.Fs.Content.S3Content do
  alias JustBash.Fs.Content.S3Content

  @doc """
  Resolve the S3-backed content by fetching from S3.

  If the content is cached, returns the cached value without fetching.
  """
  def resolve(%S3Content{cached_content: content}) when not is_nil(content) do
    {:ok, content}
  end

  def resolve(%S3Content{} = s3) do
    case S3Content.materialize(s3) do
      {:ok, content, _updated} -> {:ok, content}
      {:error, _} = err -> err
    end
  end

  @doc """
  Return the byte size of cached content, stored metadata size, or nil if unknown.
  """
  def size(%S3Content{cached_content: content}) when not is_nil(content) do
    byte_size(content)
  end

  def size(%S3Content{size: size}) when not is_nil(size), do: size
  def size(%S3Content{}), do: nil
end
