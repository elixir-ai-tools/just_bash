defmodule JustBash.Commands.Jq.Evaluator.Format do
  @moduledoc """
  Output formatting functions for jq.

  Handles conversion of jq values to various output formats:
  CSV, TSV, JSON, text, base64, URI encoding, and HTML escaping.
  """

  @doc """
  Format data according to the specified format type.

  ## Format Types
  - `:csv` - Comma-separated values
  - `:tsv` - Tab-separated values
  - `:json` - JSON encoding
  - `:text` - Plain text
  - `:base64` - Base64 encoding
  - `:base64d` - Base64 decoding
  - `:uri` - URI encoding
  - `:html` - HTML entity escaping
  """
  @spec format(atom(), any()) :: String.t()
  def format(:csv, data) when is_list(data) do
    Enum.map_join(data, ",", &format_csv_field/1)
  end

  def format(:tsv, data) when is_list(data) do
    Enum.map_join(data, "\t", &format_tsv_field/1)
  end

  def format(:json, :nan), do: "null"
  def format(:json, data), do: Jason.encode!(sanitize_nan(data))

  def format(:text, data) when is_binary(data), do: data
  def format(:text, data), do: to_string(data)

  def format(:base64, data) when is_binary(data), do: Base.encode64(data)

  def format(:base64d, data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> decoded
      :error -> throw({:eval_error, "invalid base64"})
    end
  end

  def format(:uri, data) when is_binary(data), do: URI.encode(data, &URI.char_unreserved?/1)

  def format(:urid, data) when is_binary(data), do: URI.decode(data)

  def format(:sh, data) when is_binary(data) do
    "'" <> String.replace(data, "'", "'\\''") <> "'"
  end

  def format(:html, data) when is_binary(data) do
    data
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  def format(name, _data) do
    throw({:eval_error, "unknown format: @#{name}"})
  end

  @doc """
  Convert a value to its string representation for jq output.
  """
  @spec stringify(any()) :: String.t()
  def stringify(:nan), do: "null"
  def stringify(nil), do: "null"
  def stringify(s) when is_binary(s), do: s
  def stringify(n) when is_number(n), do: to_string(n)
  def stringify(true), do: "true"
  def stringify(false), do: "false"
  def stringify(other), do: Jason.encode!(sanitize_nan(other))

  # Convert :nan atoms to nil for JSON encoding compatibility
  defp sanitize_nan(:nan), do: nil
  defp sanitize_nan(list) when is_list(list), do: Enum.map(list, &sanitize_nan/1)

  defp sanitize_nan(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, sanitize_nan(v)} end)
  end

  defp sanitize_nan(other), do: other

  # CSV field formatting
  defp format_csv_field(nil), do: ""
  defp format_csv_field(true), do: "true"
  defp format_csv_field(false), do: "false"
  defp format_csv_field(n) when is_number(n), do: to_string(n)

  defp format_csv_field(s) when is_binary(s) do
    # jq always quotes strings in CSV output
    "\"" <> String.replace(s, "\"", "\"\"") <> "\""
  end

  defp format_csv_field(other), do: Jason.encode!(other)

  # TSV field formatting
  defp format_tsv_field(nil), do: ""
  defp format_tsv_field(true), do: "true"
  defp format_tsv_field(false), do: "false"
  defp format_tsv_field(n) when is_number(n), do: to_string(n)

  defp format_tsv_field(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
    |> String.replace("\n", "\\n")
  end

  defp format_tsv_field(other), do: Jason.encode!(other)
end
