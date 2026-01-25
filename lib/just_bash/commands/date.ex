defmodule JustBash.Commands.Date do
  @moduledoc "The `date` command - display the current date and time."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @default_format "%a %b %d %H:%M:%S UTC %Y"

  @impl true
  def names, do: ["date"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:ok, opts} ->
        datetime = opts.datetime || DateTime.utc_now()
        format = opts.format || @default_format
        output = format_datetime(datetime, format) <> "\n"
        {Command.ok(output), bash}

      {:error, msg} ->
        {Command.error(msg), bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{format: nil, datetime: nil, input_format: nil, no_set: false})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["+" <> format | rest], opts) do
    parse_args(rest, %{opts | format: format})
  end

  defp parse_args(["-d", date_str | rest], opts) do
    case parse_date_string(date_str) do
      {:ok, datetime} -> parse_args(rest, %{opts | datetime: datetime})
      {:error, _} -> {:error, "date: invalid date '#{date_str}'\n"}
    end
  end

  defp parse_args(["--date=" <> date_str | rest], opts) do
    case parse_date_string(date_str) do
      {:ok, datetime} -> parse_args(rest, %{opts | datetime: datetime})
      {:error, _} -> {:error, "date: invalid date '#{date_str}'\n"}
    end
  end

  # BSD date: -j flag means "don't set the date" (just display)
  defp parse_args(["-j" | rest], opts) do
    parse_args(rest, %{opts | no_set: true})
  end

  # BSD date: -f input_format to parse a date string
  defp parse_args(["-f", input_format | rest], opts) do
    parse_args(rest, %{opts | input_format: input_format})
  end

  defp parse_args(["-u" | rest], opts) do
    parse_args(rest, opts)
  end

  # When we have an input_format set (BSD -f flag) and encounter a non-option arg
  defp parse_args([<<c, _::binary>> = date_str | rest], %{input_format: input_format} = opts)
       when input_format != nil and c != ?+ and c != ?- do
    case parse_formatted_date(date_str, input_format) do
      {:ok, datetime} ->
        parse_args(rest, %{opts | datetime: datetime, input_format: nil})

      {:error, _} ->
        {:error, "date: invalid date '#{date_str}'\n"}
    end
  end

  defp parse_args([_arg | rest], opts) do
    parse_args(rest, opts)
  end

  defp parse_formatted_date(date_str, format) do
    cond do
      format == "%Y-%m-%d %H:%M:%S" -> parse_space_datetime(date_str)
      format == "%Y-%m-%d" -> parse_date_only(date_str)
      format == "%Y-%m-%dT%H:%M:%S" -> parse_iso_datetime(date_str)
      true -> parse_date_string(date_str)
    end
  end

  defp parse_date_string(str) do
    cond do
      str =~ ~r/^\d{4}-\d{2}-\d{2}$/ -> parse_date_only(str)
      str =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/ -> parse_iso_datetime(str)
      str =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/ -> parse_space_datetime(str)
      true -> parse_relative_date(str)
    end
  end

  defp parse_date_only(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
      error -> error
    end
  end

  defp parse_iso_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_space_datetime(str) do
    iso_str = String.replace(str, " ", "T") <> "Z"

    case DateTime.from_iso8601(iso_str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_relative_date("now"), do: {:ok, DateTime.utc_now()}

  defp parse_relative_date("yesterday"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(-86_400, :second)}

  defp parse_relative_date("tomorrow"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(86_400, :second)}

  defp parse_relative_date(_), do: {:error, :invalid_format}

  defp format_datetime(datetime, format) do
    format
    |> String.replace("%Y", Integer.to_string(datetime.year) |> String.pad_leading(4, "0"))
    |> String.replace("%m", Integer.to_string(datetime.month) |> String.pad_leading(2, "0"))
    |> String.replace("%d", Integer.to_string(datetime.day) |> String.pad_leading(2, "0"))
    |> String.replace("%H", Integer.to_string(datetime.hour) |> String.pad_leading(2, "0"))
    |> String.replace("%M", Integer.to_string(datetime.minute) |> String.pad_leading(2, "0"))
    |> String.replace("%S", Integer.to_string(datetime.second) |> String.pad_leading(2, "0"))
    |> String.replace("%s", Integer.to_string(DateTime.to_unix(datetime)))
    |> String.replace("%a", short_day_name(datetime))
    |> String.replace("%A", full_day_name(datetime))
    |> String.replace("%b", short_month_name(datetime))
    |> String.replace("%B", full_month_name(datetime))
    |> String.replace("%j", day_of_year(datetime))
    |> String.replace("%u", Integer.to_string(Date.day_of_week(datetime)))
    |> String.replace("%w", Integer.to_string(rem(Date.day_of_week(datetime), 7)))
    |> String.replace("%n", "\n")
    |> String.replace("%t", "\t")
    |> String.replace("%%", "%")
  end

  defp short_day_name(dt) do
    case Date.day_of_week(dt) do
      1 -> "Mon"
      2 -> "Tue"
      3 -> "Wed"
      4 -> "Thu"
      5 -> "Fri"
      6 -> "Sat"
      7 -> "Sun"
    end
  end

  defp full_day_name(dt) do
    case Date.day_of_week(dt) do
      1 -> "Monday"
      2 -> "Tuesday"
      3 -> "Wednesday"
      4 -> "Thursday"
      5 -> "Friday"
      6 -> "Saturday"
      7 -> "Sunday"
    end
  end

  defp short_month_name(dt) do
    Enum.at(
      ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec),
      dt.month - 1
    )
  end

  defp full_month_name(dt) do
    Enum.at(
      ~w(January February March April May June July August September October November December),
      dt.month - 1
    )
  end

  defp day_of_year(dt) do
    Date.day_of_year(dt) |> Integer.to_string() |> String.pad_leading(3, "0")
  end
end
