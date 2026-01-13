defmodule JustBash.Commands.Printf do
  @moduledoc "The `printf` command - format and print data."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @format_regex ~r/%(-)?(0)?(\d+)?(?:\.(\d+))?([sdxXofec%])/

  @impl true
  def names, do: ["printf"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [format | rest] ->
        output = format_string(format, rest)
        {Command.ok(output), bash}

      [] ->
        {Command.ok(), bash}
    end
  end

  @spec format_string(String.t(), [String.t()]) :: String.t()
  defp format_string(format, args) do
    format
    |> unescape()
    |> apply_formats(args)
  end

  @spec unescape(String.t()) :: String.t()
  defp unescape(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\\", "\0ESCAPED_BACKSLASH\0")
    |> String.replace("\0ESCAPED_BACKSLASH\0", "\\")
  end

  @spec apply_formats(String.t(), [String.t()]) :: String.t()
  defp apply_formats(format, args) do
    {result, _remaining_args} =
      Regex.split(@format_regex, format, include_captures: true)
      |> process_parts(args, [])

    result
  end

  defp process_parts([], _args, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), []}

  defp process_parts([part | rest], args, acc) do
    case Regex.run(@format_regex, part) do
      nil ->
        process_parts(rest, args, [part | acc])

      [_full, left_align, zero_pad, width, precision, specifier] ->
        {formatted, remaining} =
          format_specifier(specifier, left_align, zero_pad, width, precision, args)

        process_parts(rest, remaining, [formatted | acc])
    end
  end

  defp format_specifier("%", _left, _zero, _width, _precision, args) do
    {"%", args}
  end

  defp format_specifier(spec, left_align, zero_pad, width, precision, [arg | rest]) do
    formatted = do_format(spec, arg, precision)
    padded = apply_width(formatted, left_align, zero_pad, width)
    {padded, rest}
  end

  defp format_specifier(spec, left_align, zero_pad, width, precision, []) do
    formatted = do_format(spec, "", precision)
    padded = apply_width(formatted, left_align, zero_pad, width)
    {padded, []}
  end

  defp do_format("s", arg, precision) do
    case precision do
      "" -> arg
      p -> String.slice(arg, 0, String.to_integer(p))
    end
  end

  defp do_format("d", arg, _precision) do
    case Integer.parse(arg) do
      {n, _} -> Integer.to_string(n)
      :error -> "0"
    end
  end

  defp do_format("x", arg, _precision) do
    case Integer.parse(arg) do
      {n, _} when n >= 0 -> Integer.to_string(n, 16) |> String.downcase()
      {n, _} -> "-" <> (Integer.to_string(abs(n), 16) |> String.downcase())
      :error -> "0"
    end
  end

  defp do_format("X", arg, _precision) do
    case Integer.parse(arg) do
      {n, _} when n >= 0 -> Integer.to_string(n, 16) |> String.upcase()
      {n, _} -> "-" <> (Integer.to_string(abs(n), 16) |> String.upcase())
      :error -> "0"
    end
  end

  defp do_format("o", arg, _precision) do
    case Integer.parse(arg) do
      {n, _} when n >= 0 -> Integer.to_string(n, 8)
      {n, _} -> "-" <> Integer.to_string(abs(n), 8)
      :error -> "0"
    end
  end

  defp do_format("f", arg, precision) do
    prec = parse_precision(precision, 6)

    case Float.parse(arg) do
      {f, _} -> :erlang.float_to_binary(f, decimals: prec)
      :error -> :erlang.float_to_binary(0.0, decimals: prec)
    end
  end

  defp do_format("e", arg, precision) do
    prec = parse_precision(precision, 6)

    case Float.parse(arg) do
      {f, _} -> format_scientific(f, prec)
      :error -> format_scientific(0.0, prec)
    end
  end

  defp do_format("c", arg, _precision) do
    case String.first(arg) do
      nil -> ""
      char -> char
    end
  end

  defp format_scientific(f, precision) do
    :io_lib.format("~.*e", [precision, f]) |> IO.iodata_to_binary()
  end

  defp parse_precision("", default), do: default
  defp parse_precision(p, _default), do: String.to_integer(p)

  defp apply_width(str, _left_align, _zero_pad, ""), do: str

  defp apply_width(str, left_align, zero_pad, width_str) do
    width = String.to_integer(width_str)
    len = String.length(str)

    if len >= width do
      str
    else
      pad_char = if zero_pad == "0" and left_align != "-", do: "0", else: " "
      padding = String.duplicate(pad_char, width - len)
      if left_align == "-", do: str <> padding, else: padding <> str
    end
  end
end
