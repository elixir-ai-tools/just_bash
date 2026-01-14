defmodule JustBash.Commands.ArgParserTest do
  use ExUnit.Case, async: true
  alias JustBash.Commands.ArgParser

  @basic_flags [
    verbose: [short: "-v", long: "--verbose", type: :boolean],
    output: [short: "-o", long: "--output", type: :string],
    count: [short: "-n", long: "--count", type: :integer, default: 1]
  ]

  describe "parse/3 with boolean flags" do
    test "parses short boolean flag" do
      {:ok, opts, positional} = ArgParser.parse(["-v", "file.txt"], @basic_flags)
      assert opts.verbose == true
      assert positional == ["file.txt"]
    end

    test "parses long boolean flag" do
      {:ok, opts, positional} = ArgParser.parse(["--verbose", "file.txt"], @basic_flags)
      assert opts.verbose == true
      assert positional == ["file.txt"]
    end

    test "defaults to false for unspecified boolean" do
      {:ok, opts, _} = ArgParser.parse(["file.txt"], @basic_flags)
      assert opts.verbose == false
    end
  end

  describe "parse/3 with string flags" do
    test "parses short string flag" do
      {:ok, opts, positional} = ArgParser.parse(["-o", "out.txt", "file.txt"], @basic_flags)
      assert opts.output == "out.txt"
      assert positional == ["file.txt"]
    end

    test "parses long string flag" do
      {:ok, opts, _} = ArgParser.parse(["--output", "out.txt"], @basic_flags)
      assert opts.output == "out.txt"
    end

    test "parses long flag with equals sign" do
      {:ok, opts, _} = ArgParser.parse(["--output=out.txt"], @basic_flags)
      assert opts.output == "out.txt"
    end
  end

  describe "parse/3 with integer flags" do
    test "parses integer flag" do
      {:ok, opts, _} = ArgParser.parse(["-n", "10"], @basic_flags)
      assert opts.count == 10
    end

    test "uses default for unspecified integer" do
      {:ok, opts, _} = ArgParser.parse([], @basic_flags)
      assert opts.count == 1
    end
  end

  describe "parse/3 with accumulator flags" do
    @header_flags [
      header: [short: "-H", long: "--header", type: :accumulator, default: []]
    ]

    test "accumulates multiple values" do
      {:ok, opts, _} =
        ArgParser.parse(
          ["-H", "Content-Type: application/json", "-H", "Accept: text/plain"],
          @header_flags
        )

      assert opts.header == ["Content-Type: application/json", "Accept: text/plain"]
    end

    test "defaults to empty list" do
      {:ok, opts, _} = ArgParser.parse([], @header_flags)
      assert opts.header == []
    end
  end

  describe "parse/3 with unknown flags" do
    test "returns error for unknown flag" do
      {:error, msg} = ArgParser.parse(["--unknown"], @basic_flags, command: "test")
      assert msg =~ "unknown option"
      assert msg =~ "--unknown"
    end

    test "allows unknown flags when allow_unknown is true" do
      {:ok, _opts, positional} =
        ArgParser.parse(["--unknown", "file.txt"], @basic_flags, allow_unknown: true)

      assert "--unknown" in positional
    end
  end

  describe "parse/3 special cases" do
    test "stops parsing flags after --" do
      {:ok, opts, positional} =
        ArgParser.parse(["-v", "--", "-o", "file.txt"], @basic_flags)

      assert opts.verbose == true
      assert opts.output == nil
      assert positional == ["-o", "file.txt"]
    end

    test "handles multiple positional arguments" do
      {:ok, _opts, positional} =
        ArgParser.parse(["file1.txt", "file2.txt", "file3.txt"], @basic_flags)

      assert positional == ["file1.txt", "file2.txt", "file3.txt"]
    end

    test "handles interleaved flags and positional" do
      {:ok, opts, positional} =
        ArgParser.parse(["file1.txt", "-v", "file2.txt"], @basic_flags)

      assert opts.verbose == true
      assert positional == ["file1.txt", "file2.txt"]
    end
  end

  describe "transform option" do
    @transform_flags [
      method: [
        short: "-X",
        type: :string,
        default: "GET",
        transform: &String.upcase/1
      ]
    ]

    test "applies transform function to value" do
      {:ok, opts, _} = ArgParser.parse(["-X", "post"], @transform_flags)
      assert opts.method == "POST"
    end
  end
end
