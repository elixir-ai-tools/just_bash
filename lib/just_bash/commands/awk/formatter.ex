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
    |> Parser.unescape_string()
    |> do_format(values, [])
    |> IO.iodata_to_binary()
  end

  # Process format string character by character, building output as iodata
  defp do_format("", _values, acc), do: Enum.reverse(acc)

  defp do_format("%" <> rest, values, acc) do
    {formatted, remaining_format, remaining_values} = parse_and_format_specifier(rest, values)
    do_format(remaining_format, remaining_values, [formatted | acc])
  end

  defp do_format(<<char::utf8, rest::binary>>, values, acc) do
    do_format(rest, values, [<<char::utf8>> | acc])
  end

  # Parse format specifier and return {formatted_string, remaining_format, remaining_values}
  defp parse_and_format_specifier(str, values) do
    # Match: optional flags (-0), optional width, optional .precision, then type
    case Regex.run(~r/^(-?0?)(\d*)(?:\.(\d+))?([sdfc%xXoeg])(.*)$/s, str) do
      [_, flags, width, precision, type, rest] ->
        {formatted, remaining_values} = format_specifier(flags, width, precision, type, values)
        {formatted, rest, remaining_values}

      nil ->
        # No valid specifier, output literal %
        {"%", str, values}
    end
  end

  defp format_specifier(_flags, _width, _precision, "%", values) do
    {"%", values}
  end

  defp format_specifier(flags, width, precision, "s", values) do
    {val, rest} = pop_value(values, "")
    str = to_string(val)
    formatted = apply_string_format(str, flags, width, precision)
    {formatted, rest}
  end

  defp format_specifier(flags, width, _precision, "d", values) do
    {val, rest} = pop_value(values, 0)
    num = parse_number(val) |> trunc()
    formatted = apply_int_format(num, flags, width)
    {formatted, rest}
  end

  defp format_specifier(flags, width, precision, "f", values) do
    {val, rest} = pop_value(values, 0.0)
    num = parse_number(val)
    formatted = apply_float_format(num, flags, width, precision)
    {formatted, rest}
  end

  defp format_specifier(flags, width, precision, "e", values) do
    {val, rest} = pop_value(values, 0.0)
    num = parse_number(val)
    formatted = apply_scientific_format(num, flags, width, precision)
    {formatted, rest}
  end

  defp format_specifier(flags, width, precision, "g", values) do
    # %g uses %e or %f, whichever is shorter
    {val, rest} = pop_value(values, 0.0)
    num = parse_number(val)
    formatted = apply_general_format(num, flags, width, precision)
    {formatted, rest}
  end

  defp format_specifier(_flags, _width, _precision, "c", values) do
    {val, rest} = pop_value(values, "")
    char = extract_char(val)
    {char, rest}
  end

  defp format_specifier(flags, width, _precision, "x", values) do
    {val, rest} = pop_value(values, 0)
    num = parse_number(val) |> trunc()
    hex = Integer.to_string(num, 16) |> String.downcase()
    formatted = apply_int_format_str(hex, flags, width, num >= 0)
    {formatted, rest}
  end

  defp format_specifier(flags, width, _precision, "X", values) do
    {val, rest} = pop_value(values, 0)
    num = parse_number(val) |> trunc()
    hex = Integer.to_string(num, 16) |> String.upcase()
    formatted = apply_int_format_str(hex, flags, width, num >= 0)
    {formatted, rest}
  end

  defp format_specifier(flags, width, _precision, "o", values) do
    {val, rest} = pop_value(values, 0)
    num = parse_number(val) |> trunc()
    octal = Integer.to_string(num, 8)
    formatted = apply_int_format_str(octal, flags, width, num >= 0)
    {formatted, rest}
  end

  defp format_specifier(_flags, _width, _precision, _type, values) do
    {val, rest} = pop_value(values, "")
    {to_string(val), rest}
  end

  defp pop_value([], default), do: {default, []}
  defp pop_value([val | rest], _default), do: {val, rest}

  defp extract_char(val) when is_integer(val), do: <<val::utf8>>
  defp extract_char(val) when is_binary(val) and val != "", do: String.first(val)
  defp extract_char(_), do: ""

  # String formatting
  defp apply_string_format(str, flags, width, precision) do
    # Apply precision (max length) first
    str = if precision != "", do: String.slice(str, 0, parse_int(precision, 0)), else: str

    # Then apply width padding
    width_num = parse_int(width, 0)

    if String.contains?(flags, "-") do
      String.pad_trailing(str, width_num)
    else
      String.pad_leading(str, width_num)
    end
  end

  # Integer formatting
  defp apply_int_format(num, flags, width) do
    str = Integer.to_string(abs(num))
    apply_int_format_str(str, flags, width, num >= 0)
  end

  defp apply_int_format_str(str, flags, width, is_positive) do
    width_num = parse_int(width, 0)
    sign = if is_positive, do: "", else: "-"

    cond do
      String.contains?(flags, "0") and not String.contains?(flags, "-") ->
        # Zero-pad
        pad_width = max(0, width_num - String.length(sign))
        sign <> String.pad_leading(str, pad_width, "0")

      String.contains?(flags, "-") ->
        # Left-align
        String.pad_trailing(sign <> str, width_num)

      true ->
        # Right-align with spaces
        String.pad_leading(sign <> str, width_num)
    end
  end

  # Float formatting
  defp apply_float_format(num, flags, width, precision) do
    prec = parse_int(precision, 6)
    str = :erlang.float_to_binary(num * 1.0, decimals: prec)
    width_num = parse_int(width, 0)

    cond do
      String.contains?(flags, "-") ->
        String.pad_trailing(str, width_num)

      String.contains?(flags, "0") ->
        # Zero-pad floats (handle sign)
        if num < 0 do
          "-" <> String.pad_leading(String.trim_leading(str, "-"), width_num - 1, "0")
        else
          String.pad_leading(str, width_num, "0")
        end

      true ->
        String.pad_leading(str, width_num)
    end
  end

  # Scientific notation
  defp apply_scientific_format(num, _flags, _width, precision) do
    prec = parse_int(precision, 6)
    # Format as scientific notation
    if num == 0 do
      "0." <> String.duplicate("0", prec) <> "e+0"
    else
      exp = :math.floor(:math.log10(abs(num))) |> trunc()
      mantissa = num / :math.pow(10, exp)
      mantissa_str = :erlang.float_to_binary(mantissa * 1.0, decimals: prec)
      exp_sign = if exp >= 0, do: "+", else: ""
      "#{mantissa_str}e#{exp_sign}#{exp}"
    end
  end

  # General format (shorter of %e or %f)
  defp apply_general_format(num, flags, width, precision) do
    # Simplified: just use %f for now
    apply_float_format(num, flags, width, precision)
  end

  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
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
