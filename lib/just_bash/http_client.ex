defmodule JustBash.HttpClient do
  @moduledoc """
  Behaviour for HTTP clients used by curl command.

  Implement this behaviour to provide custom HTTP handling for testing
  or to use a different HTTP library.
  """

  @type method :: :get | :post | :put | :delete | :patch | :head | :options

  @type request :: %{
          method: method(),
          url: String.t(),
          headers: map(),
          body: String.t() | nil,
          timeout: non_neg_integer(),
          follow_redirects: boolean(),
          insecure: boolean()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t() | nil
        }

  @type error :: %{reason: atom() | String.t()}

  @callback request(request()) :: {:ok, response()} | {:error, error()}

  defmodule Default do
    @moduledoc "Default HTTP client using Req library."
    @behaviour JustBash.HttpClient

    @max_redirects 20

    @impl true
    def request(req) do
      req_opts = [
        method: req.method,
        url: req.url,
        headers: req.headers,
        body: req.body,
        connect_options: connect_options(req),
        receive_timeout: req.timeout,
        redirect: req.follow_redirects,
        max_redirects: @max_redirects
      ]

      case Req.request(req_opts) do
        {:ok, response} ->
          {:ok,
           %{
             status: response.status,
             headers: response.headers,
             body: response.body
           }}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, %{reason: reason}}

        {:error, %{reason: reason}} ->
          {:error, %{reason: reason}}

        {:error, reason} ->
          {:error, %{reason: reason}}
      end
    end

    defp connect_options(req) do
      opts = [timeout: req.timeout]

      if req.insecure do
        Keyword.put(opts, :transport_opts, verify: :verify_none)
      else
        opts
      end
    end
  end
end
