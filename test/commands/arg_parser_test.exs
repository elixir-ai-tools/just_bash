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

    test "rejects a value with trailing characters" do
      assert {:error, message} = ArgParser.parse(["-n", "10x"], @basic_flags)
      assert message =~ "invalid integer value: 10x"
    end

    test "rejects an underscore-separated value rather than silently truncating" do
      assert {:error, message} = ArgParser.parse(["-n", "1_000"], @basic_flags)
      assert message =~ "invalid integer value: 1_000"
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

  describe "parse/3 with collect_unknown" do
    test "returns a 4-tuple collecting unknown flags into extra" do
      {:ok, opts, positional, extra} =
        ArgParser.parse(["-v", "target", "--dyn", "x"], @basic_flags, collect_unknown: true)

      assert opts.verbose == true
      assert positional == ["target"]
      assert extra == ["--dyn", "x"]
    end

    test "forwards --flag=value as a single token" do
      {:ok, _opts, _positional, extra} =
        ArgParser.parse(["--dyn=x"], @basic_flags, collect_unknown: true)

      assert extra == ["--dyn=x"]
    end

    test "does not consume a following flag as a value" do
      {:ok, opts, _positional, extra} =
        ArgParser.parse(["--dyn", "-v"], @basic_flags, collect_unknown: true)

      assert opts.verbose == true
      assert extra == ["--dyn"]
    end

    test "collects unknown short flags and their value" do
      {:ok, _opts, positional, extra} =
        ArgParser.parse(["target", "-Z", "val"], @basic_flags, collect_unknown: true)

      assert positional == ["target"]
      assert extra == ["-Z", "val"]
    end

    test "known flags and positionals stay out of extra" do
      {:ok, opts, positional, extra} =
        ArgParser.parse(["-o", "out", "file", "--dyn", "v"], @basic_flags, collect_unknown: true)

      assert opts.output == "out"
      assert positional == ["file"]
      assert extra == ["--dyn", "v"]
    end

    test "no unknown flags yields an empty extra list" do
      {:ok, _opts, positional, extra} =
        ArgParser.parse(["-v", "file"], @basic_flags, collect_unknown: true)

      assert positional == ["file"]
      assert extra == []
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

  describe "transform error channel" do
    defp ratio_flags do
      [
        ratio: [
          long: "--ratio",
          type: :float,
          transform: fn f ->
            if f >= 0.0 and f <= 1.0, do: {:ok, f}, else: {:error, "ratio must be in 0.0..1.0"}
          end
        ]
      ]
    end

    test "returns the value when transform returns {:ok, v}" do
      {:ok, opts, _} = ArgParser.parse(["--ratio", "0.5"], ratio_flags())
      assert opts.ratio == 0.5
    end

    test "errors when transform returns {:error, msg}" do
      assert {:error, msg} = ArgParser.parse(["--ratio", "2.0"], ratio_flags())
      assert msg =~ "ratio must be in 0.0..1.0"
    end

    test "still supports a bare-value transform" do
      {:ok, opts, _} = ArgParser.parse(["-X", "post"], @transform_flags)
      assert opts.method == "POST"
    end

    test "raises when transform returns {:error, non_binary} rather than silently passing it" do
      flags = [n: [long: "--n", type: :integer, transform: fn _ -> {:error, :not_a_string} end]]

      assert_raise ArgumentError, ~r/error message must be a String\.t\(\)/, fn ->
        ArgParser.parse(["--n", "1"], flags)
      end
    end
  end

  describe "float type" do
    @float_flags [
      ratio: [long: "--ratio", type: :float]
    ]

    test "parses a float value" do
      {:ok, opts, _} = ArgParser.parse(["--ratio", "1.5"], @float_flags)
      assert opts.ratio == 1.5
    end

    test "parses an integer-looking value as a float" do
      {:ok, opts, _} = ArgParser.parse(["--ratio", "2"], @float_flags)
      assert opts.ratio == 2.0
    end

    test "errors on a non-numeric value" do
      assert {:error, message} = ArgParser.parse(["--ratio", "abc"], @float_flags)
      assert message =~ "invalid float value: abc"
    end

    test "rejects a value with trailing characters" do
      assert {:error, message} = ArgParser.parse(["--ratio", "1.5.6"], @float_flags)
      assert message =~ "invalid float value: 1.5.6"
    end
  end

  describe "required option" do
    @required_flags [
      report: [long: "--report", type: :integer, required: true],
      format: [long: "--format", type: :string, default: "text"]
    ]

    test "succeeds when the required flag is provided" do
      {:ok, opts, _} = ArgParser.parse(["--report", "12"], @required_flags)
      assert opts.report == 12
    end

    test "errors when a required flag is missing" do
      assert {:error, message} = ArgParser.parse([], @required_flags)
      assert message =~ "missing required flag: --report"
    end

    test "includes the command name in the required error when given" do
      assert {:error, message} =
               ArgParser.parse([], @required_flags, command: "acme pr review")

      assert message =~ "acme pr review: missing required flag: --report"
    end

    test "uses the short flag name in the error when no long form exists" do
      flags = [count: [short: "-n", type: :integer, required: true]]
      assert {:error, message} = ArgParser.parse([], flags)
      assert message =~ "missing required flag: -n"
    end
  end

  describe "values (enum) option" do
    @enum_flags [
      format: [long: "--format", type: :string, values: ["text", "json"], default: "text"]
    ]

    test "accepts an allowed value" do
      {:ok, opts, _} = ArgParser.parse(["--format", "json"], @enum_flags)
      assert opts.format == "json"
    end

    test "errors on a disallowed value" do
      assert {:error, message} = ArgParser.parse(["--format", "yaml"], @enum_flags)
      assert message =~ "invalid value for --format: yaml"
      assert message =~ "text, json"
    end

    test "allows the default when the flag is omitted" do
      {:ok, opts, _} = ArgParser.parse([], @enum_flags)
      assert opts.format == "text"
    end
  end
end
