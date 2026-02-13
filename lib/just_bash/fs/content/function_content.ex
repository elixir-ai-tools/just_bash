defmodule JustBash.Fs.Content.FunctionContent do
  @moduledoc """
  File content backed by a function.

  The function is called each time the file is read (unless cached via `materialize/1`).

  ## Supported function types

  - Zero-arity anonymous functions: `fn -> "content" end`
  - Captured functions: `&MyModule.generate/0`
  - MFA tuples: `{Module, :function, [args]}`

  ## Examples

      # Anonymous function
      fc = FunctionContent.new(fn -> "generated at \#{DateTime.utc_now()}" end)

      # MFA tuple (serialization-friendly)
      fc = FunctionContent.new({MyModule, :generate_content, ["arg1"]})

      # Materialize to cache the result
      {:ok, content, cached_fc} = FunctionContent.materialize(fc)
  """

  @type fun_spec :: (-> String.t()) | {module(), atom(), [term()]}

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

      iex> FunctionContent.new({String, :upcase, ["hello"]})
      %FunctionContent{fun: {String, :upcase, ["hello"]}, cached_content: nil}
  """
  @spec new(fun_spec()) :: t()
  def new(fun) when is_function(fun, 0), do: %__MODULE__{fun: fun}

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
    case call_fun(fun) do
      {:ok, content} when is_binary(content) ->
        {:ok, content, %{fc | cached_content: content}}

      {:error, _} = err ->
        err
    end
  end

  defp call_fun(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    e -> {:error, {:function_error, Exception.message(e)}}
  end

  defp call_fun({m, f, a}) do
    {:ok, apply(m, f, a)}
  rescue
    e -> {:error, {:function_error, Exception.message(e)}}
  end
end

defimpl JustBash.Fs.ContentAdapter, for: JustBash.Fs.Content.FunctionContent do
  alias JustBash.Fs.Content.FunctionContent

  @doc """
  Resolve the function-backed content by calling the function.

  If the content is cached, returns the cached value without calling the function.
  """
  def resolve(%FunctionContent{cached_content: content}) when not is_nil(content) do
    {:ok, content}
  end

  def resolve(%FunctionContent{} = fc) do
    case FunctionContent.materialize(fc) do
      {:ok, content, _updated} -> {:ok, content}
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
