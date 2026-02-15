defmodule JustBash.Fs.Content.FunctionContent do
  @moduledoc """
  File content backed by a function.

  The function is called each time the file is read (unless cached via `materialize/1`).

  ## Supported function types

  - Zero-arity: `fn -> "content" end`
  - One-arity (receives bash state): `fn bash -> "Hello " <> bash.env["USER"] end`
  - One-arity (modifies bash state): `fn bash -> {"content", updated_bash} end`
  - Captured functions: `&MyModule.generate/1`
  - MFA tuples: `{Module, :function, [args]}`

  ## Examples

      # Zero-arity (static generation)
      fc = FunctionContent.new(fn -> "generated at " <> to_string(DateTime.utc_now()) end)

      # One-arity (access bash state)
      fc = FunctionContent.new(fn bash -> "User: " <> bash.env["USER"] end)

      # One-arity (modify bash state)
      fc = FunctionContent.new(fn bash ->
        new_bash = %{bash | env: Map.put(bash.env, "READ_COUNT", "1")}
        {"content", new_bash}
      end)

      # MFA tuple (serialization-friendly)
      fc = FunctionContent.new({MyModule, :generate_content, []})

      # Materialize to cache the result
      {:ok, content, cached_fc} = FunctionContent.materialize(fc)
  """

  @type fun_spec ::
          (-> String.t())
          | (JustBash.t() -> String.t())
          | (JustBash.t() -> {String.t(), JustBash.t()})
          | {module(), atom(), [term()]}

  @type t :: %__MODULE__{
          fun: fun_spec(),
          cached_content: binary() | nil
        }

  @enforce_keys [:fun]
  defstruct [:fun, cached_content: nil]

  @doc """
  Create a new function-backed content source.

  ## Examples

      iex> FunctionContent.new(fn -> "hello" end)
      %FunctionContent{fun: fn -> "hello" end, cached_content: nil}

      iex> FunctionContent.new(fn bash -> bash.env["USER"] end)
      %FunctionContent{fun: fn bash -> bash.env["USER"] end, cached_content: nil}

      iex> FunctionContent.new({String, :upcase, ["hello"]})
      %FunctionContent{fun: {String, :upcase, ["hello"]}, cached_content: nil}
  """
  @spec new(fun_spec()) :: t()
  def new(fun) when is_function(fun, 0), do: %__MODULE__{fun: fun}
  def new(fun) when is_function(fun, 1), do: %__MODULE__{fun: fun}

  def new({m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a),
    do: %__MODULE__{fun: mfa}

  @doc """
  Materialize the content by calling the function and caching the result.

  Returns `{:ok, binary, updated_struct}` with the cached content.

  ## Examples

      iex> fc = FunctionContent.new(fn -> "hello" end)
      iex> {:ok, content, cached_fc} = FunctionContent.materialize(fc)
      iex> content
      "hello"
      iex> cached_fc.cached_content
      "hello"
  """
  @spec materialize(t()) :: {:ok, binary(), t()} | {:error, term()}
  def materialize(%__MODULE__{cached_content: content} = fc) when not is_nil(content) do
    {:ok, content, fc}
  end

  def materialize(%__MODULE__{fun: fun} = fc) do
    # Materialize doesn't have bash context, so pass nil
    case call_fun(fun, nil) do
      {:ok, content, _bash} when is_binary(content) ->
        {:ok, content, %{fc | cached_content: content}}

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def call_fun(fun, bash)

  def call_fun(fun, _bash) when is_function(fun, 0) do
    result = fun.()
    {:ok, result, nil}
  rescue
    e -> {:error, {:function_error, Exception.message(e)}}
  end

  def call_fun(fun, bash) when is_function(fun, 1) do
    case fun.(bash) do
      {content, new_bash} when is_binary(content) ->
        {:ok, content, new_bash}

      content when is_binary(content) ->
        {:ok, content, bash}

      other ->
        {:error, {:function_error, "Expected binary or {binary, bash}, got: #{inspect(other)}"}}
    end
  rescue
    e -> {:error, {:function_error, Exception.message(e)}}
  end

  def call_fun({m, f, a}, bash) do
    # MFA tuples receive bash as first arg if function is arity-1
    # Check if function exists and its arity
    case function_exported?(m, f, length(a)) do
      true ->
        result = apply(m, f, a)
        {:ok, result, bash}

      false ->
        # Try with bash prepended
        case function_exported?(m, f, length(a) + 1) do
          true ->
            case apply(m, f, [bash | a]) do
              {content, new_bash} when is_binary(content) ->
                {:ok, content, new_bash}

              content when is_binary(content) ->
                {:ok, content, bash}

              other ->
                {:error,
                 {:function_error, "Expected binary or {binary, bash}, got: #{inspect(other)}"}}
            end

          false ->
            {:error, {:function_error, "Function #{m}.#{f}/#{length(a)} not found"}}
        end
    end
  rescue
    e -> {:error, {:function_error, Exception.message(e)}}
  end
end

defimpl JustBash.Fs.ContentAdapter, for: JustBash.Fs.Content.FunctionContent do
  alias JustBash.Fs.Content.FunctionContent

  @doc """
  Resolve the function-backed content by calling the function with bash state.

  If the content is cached, returns the cached value without calling the function.
  """
  def resolve(%FunctionContent{cached_content: content}, bash) when not is_nil(content) do
    {:ok, content, bash}
  end

  def resolve(%FunctionContent{fun: fun}, bash) do
    case FunctionContent.call_fun(fun, bash) do
      {:ok, content, new_bash} when is_nil(new_bash) -> {:ok, content, bash}
      {:ok, content, new_bash} -> {:ok, content, new_bash}
      {:error, _} = err -> err
    end
  end

  @doc """
  Return the byte size of cached content, or nil if not yet materialized.
  """
  def size(%FunctionContent{cached_content: content}) when not is_nil(content) do
    byte_size(content)
  end

  def size(%FunctionContent{}), do: nil
end
