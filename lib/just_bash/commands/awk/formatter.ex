defmodule JustBash.Commands.Awk.Formatter do
  @moduledoc """
  Formatter for AWK printf operations.

  Handles printf-style formatting with width and precision specifiers.
  """

  alias JustBash.Commands.Awk.Parser

  @doc """
  Format a printf string with the given values.
  """
  @spec format_printf(String.t(), [any()]) :: String.t()
  def format_printf(format, values) do
    format
    |> format_specifiers(values)
    |> Parser.unescape_string()
  end

  defp format_specifiers(format, values) do
    {result, _remaining} =
      Regex.scan(~r/%(-?\d*\.?\d*)?([sdfc%])/, format, return: :index)
      |> Enum.reduce({format, values}, fn matches, {fmt, vals} ->
        [{start, len} | _] = matches
        spec = String.slice(fmt, start, len)
        {replacement, new_vals} = format_single_specifier(spec, vals)

        new_fmt =
          String.slice(fmt, 0, start) <>
            replacement <> String.slice(fmt, start + len, String.length(fmt))

        {new_fmt, new_vals}
      end)

    result
  end

  defp format_single_specifier("%" <> rest, vals) do
    type = String.last(rest)
    width_spec = String.slice(rest, 0..-2//1)
    format_by_type(type, width_spec, vals)
  end

  defp format_by_type("%", _width_spec, vals), do: {"%", vals}

  defp format_by_type("s", width_spec, vals) do
    {val, rest_vals} = pop_value(vals, "")
    {apply_width(to_string(val), width_spec), rest_vals}
  end

  defp format_by_type("d", width_spec, vals) do
    {val, rest_vals} = pop_value(vals, 0)
    num = parse_number(val) |> trunc()
    {apply_int_width(num, width_spec), rest_vals}
  end

  defp format_by_type("f", width_spec, vals) do
    {val, rest_vals} = pop_value(vals, 0.0)
    num = parse_number(val)
    {apply_float_width(num, width_spec), rest_vals}
  end

  defp format_by_type("c", _width_spec, vals) do
    {val, rest_vals} = pop_value(vals, "")
    char = extract_first_char(val)
    {char, rest_vals}
  end

  defp format_by_type(_type, _width_spec, vals) do
    {val, rest_vals} = pop_value(vals, "")
    {to_string(val), rest_vals}
  end

  defp pop_value([], default), do: {default, []}
  defp pop_value([val | rest], _default), do: {val, rest}

  defp extract_first_char(s) when is_binary(s) and s != "", do: String.first(s)
  defp extract_first_char(_), do: ""

  defp apply_width(str, ""), do: str

  defp apply_width(str, spec) do
    case Integer.parse(spec) do
      {width, _} when width < 0 ->
        String.pad_trailing(str, abs(width))

      {width, _} ->
        String.pad_leading(str, width)

      :error ->
        str
    end
  end

  # Integer width with zero-padding support
  defp apply_int_width(num, ""), do: to_string(num)

  defp apply_int_width(num, spec) do
    cond do
      # Zero-padded: 05, 010, etc.
      String.starts_with?(spec, "0") ->
        case Integer.parse(spec) do
          {width, _} ->
            str = to_string(abs(num))
            sign = if num < 0, do: "-", else: ""
            padded = String.pad_leading(str, width - String.length(sign), "0")
            sign <> padded

          :error ->
            to_string(num)
        end

      # Left-aligned: -5, -10, etc.
      String.starts_with?(spec, "-") ->
        case Integer.parse(spec) do
          {width, _} ->
            String.pad_trailing(to_string(num), abs(width))

          :error ->
            to_string(num)
        end

      # Right-aligned with spaces
      true ->
        case Integer.parse(spec) do
          {width, _} ->
            String.pad_leading(to_string(num), width)

          :error ->
            to_string(num)
        end
    end
  end

  defp apply_float_width(num, "") do
    :erlang.float_to_binary(num, decimals: 6)
  end

  defp apply_float_width(num, spec) do
    case Regex.run(~r/^(-?\d*)\.?(\d*)$/, spec) do
      [_, width_str, precision_str] ->
        precision =
          case Integer.parse(precision_str) do
            {p, _} -> p
            :error -> 6
          end

        result = :erlang.float_to_binary(num, decimals: precision)

        case Integer.parse(width_str) do
          {width, _} when width < 0 ->
            String.pad_trailing(result, abs(width))

          {width, _} ->
            String.pad_leading(result, width)

          :error ->
            result
        end

      nil ->
        :erlang.float_to_binary(num, decimals: 6)
    end
  end

  defp parse_number(value) when is_number(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp parse_number(_), do: 0.0
end
