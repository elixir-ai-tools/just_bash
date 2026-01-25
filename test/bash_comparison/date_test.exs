defmodule JustBash.BashComparison.DateTest do
  use ExUnit.Case, async: false
  import JustBash.BashComparison.Support

  @moduletag :bash_comparison

  # Check if we can use GNU date syntax
  @gnu_date_available (
    case System.cmd("bash", ["-c", "date -d '2024-01-01' '+%Y' 2>/dev/null"]) do
      {"2024\n", 0} -> true
      _ ->
        case System.cmd("bash", ["-c", "command -v gdate >/dev/null 2>&1 && echo yes"]) do
          {"yes\n", 0} -> :gdate
          _ -> false
        end
    end
  )

  defp date_cmd(date_str, format) do
    case @gnu_date_available do
      true -> "date -d '#{date_str}' '+#{format}'"
      :gdate -> "gdate -d '#{date_str}' '+#{format}'"
      false ->
        {bsd_input, bsd_format} = iso_to_bsd_format(date_str)
        "date -j -f '#{bsd_format}' '#{bsd_input}' '+#{format}'"
    end
  end

  defp iso_to_bsd_format(date_str) do
    cond do
      String.match?(date_str, ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/) ->
        {date_str, "%Y-%m-%d %H:%M:%S"}
      String.match?(date_str, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/) ->
        {String.replace(date_str, "T", " "), "%Y-%m-%d %H:%M:%S"}
      String.match?(date_str, ~r/^\d{4}-\d{2}-\d{2}$/) ->
        {date_str, "%Y-%m-%d"}
      true ->
        {date_str, "%Y-%m-%d"}
    end
  end

  describe "date format strings" do
    test "year format %Y" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%Y"))
    end

    test "month format %m" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%m"))
    end

    test "day format %d" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%d"))
    end

    test "hour format %H" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%H"))
    end

    test "minute format %M" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%M"))
    end

    test "second format %S" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%S"))
    end

    test "combined date format %Y-%m-%d" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%Y-%m-%d"))
    end

    test "combined time format %H:%M:%S" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%H:%M:%S"))
    end

    test "combined datetime format" do
      compare_bash(date_cmd("2024-06-15 10:30:00", "%Y-%m-%d %H:%M:%S"))
    end
  end

  describe "date day and month names" do
    test "short day name %a (Saturday)" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%a"))
    end

    test "full day name %A (Saturday)" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%A"))
    end

    test "short month name %b (June)" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%b"))
    end

    test "full month name %B (June)" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%B"))
    end

    test "Monday %a" do
      compare_bash(date_cmd("2024-06-17 00:00:00", "%a"))
    end

    test "Sunday %a" do
      compare_bash(date_cmd("2024-06-16 00:00:00", "%a"))
    end
  end

  describe "date special formats" do
    test "day of year %j" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%j"))
    end

    test "day of week %u (Mon=1, Sun=7)" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%u"))
    end

    test "day of week %w (Sun=0, Sat=6)" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%w"))
    end

    test "unix timestamp %s" do
      compare_bash("TZ=UTC " <> date_cmd("2024-06-15 00:00:00", "%s"))
    end

    test "literal percent %%" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%%"))
    end

    test "newline %n" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "line1%nline2"))
    end

    test "tab %t" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "col1%tcol2"))
    end
  end

  describe "date edge cases" do
    test "year boundary" do
      compare_bash(date_cmd("2024-12-31 00:00:00", "%Y-%m-%d"))
    end

    test "leap year" do
      compare_bash(date_cmd("2024-02-29 00:00:00", "%Y-%m-%d"))
    end

    test "first day of year" do
      compare_bash(date_cmd("2024-01-01 00:00:00", "%j"))
    end

    test "last day of year" do
      compare_bash(date_cmd("2024-12-31 00:00:00", "%j"))
    end

    test "midnight" do
      compare_bash(date_cmd("2024-06-15 00:00:00", "%H:%M:%S"))
    end

    test "end of day" do
      compare_bash(date_cmd("2024-06-15 23:59:59", "%H:%M:%S"))
    end

    test "January month names" do
      compare_bash(date_cmd("2024-01-15 00:00:00", "%b %B"))
    end

    test "December month names" do
      compare_bash(date_cmd("2024-12-15 00:00:00", "%b %B"))
    end
  end
end
