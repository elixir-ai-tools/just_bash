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

        {replacement, new_vals} =
          case spec do
            "%" <> rest ->
              type = String.last(rest)
              width_spec = String.slice(rest, 0..-2//1)

              case type do
                "%" ->
                  {"%", vals}

                "s" ->
                  [val | rest_vals] = if vals == [], do: [""], else: vals
                  {apply_width(to_string(val), width_spec), rest_vals}

                "d" ->
                  [val | rest_vals] = if vals == [], do: [0], else: vals
                  num = parse_number(val) |> trunc()
                  {apply_width(to_string(num), width_spec), rest_vals}

                "f" ->
                  [val | rest_vals] = if vals == [], do: [0.0], else: vals
                  num = parse_number(val)
                  {apply_float_width(num, width_spec), rest_vals}

                "c" ->
                  [val | rest_vals] = if vals == [], do: [""], else: vals

                  char =
                    case val do
                      s when is_binary(s) and s != "" -> String.first(s)
                      _ -> ""
                    end

                  {char, rest_vals}

                _ ->
                  [val | rest_vals] = if vals == [], do: [""], else: vals
                  {to_string(val), rest_vals}
              end
          end

        new_fmt =
          String.slice(fmt, 0, start) <>
            replacement <> String.slice(fmt, start + len, String.length(fmt))

        {new_fmt, new_vals}
      end)

    result
  end

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
