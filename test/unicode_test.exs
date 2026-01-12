defmodule JustBash.UnicodeTest do
  @moduledoc """
  Tests for Unicode support in JustBash.

  These tests verify that multi-byte UTF-8 characters are handled correctly
  in various contexts: double-quoted strings, variable expansion, heredocs,
  command substitution, and parameter expansion.
  """
  use ExUnit.Case, async: true

  # Helper to build unicode strings without source file encoding issues
  defp degree, do: "\u00B0"
  defp euro, do: "\u20AC"
  defp pound, do: "\u00A3"
  defp yen, do: "\u00A5"
  defp arrow_right, do: "\u2192"
  defp arrow_left, do: "\u2190"
  defp star, do: "\u2605"
  defp wave, do: "\u{1F44B}"
  defp cafe, do: "caf\u00E9"
  defp naive, do: "na\u00EFve"
  defp resume, do: "r\u00E9sum\u00E9"
  defp hello_umlaut, do: "h\u00EBllo"
  defp trademark, do: "\u2122"
  defp copyright, do: "\u00A9"
  defp approx, do: "\u2248"
  defp laquo, do: "\u00AB"
  defp raquo, do: "\u00BB"
  defp e_acute, do: "\u00E9"
  defp world_umlaut, do: "w\u00F6rld"
  defp test_umlaut, do: "t\u00EBst"
  defp default_val, do: "d\u00E9fault"
  defp japanese_text, do: "\u65E5\u672C\u8A9E\u30C6\u30B9\u30C8\u6587\u5B57\u5217\u3067\u3059"
  defp chinese, do: "\u4F60\u597D\u4E16\u754C"
  defp japanese, do: "\u3053\u3093\u306B\u3061\u306F"

  describe "unicode in double-quoted strings" do
    test "degree symbol" do
      cmd = "echo \"42#{degree()}F\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "42#{degree()}F\n"
    end

    test "emoji" do
      cmd = "echo \"hello #{wave()} world\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "hello #{wave()} world\n"
    end

    test "accented characters" do
      cmd = "echo \"#{cafe()} #{resume()} #{naive()}\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{cafe()} #{resume()} #{naive()}\n"
    end

    test "chinese characters" do
      cmd = "echo \"#{chinese()}\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{chinese()}\n"
    end

    test "japanese characters" do
      cmd = "echo \"#{japanese()}\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{japanese()}\n"
    end

    test "currency symbols" do
      cmd = "echo \"#{euro()}100 #{pound()}50 #{yen()}1000\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{euro()}100 #{pound()}50 #{yen()}1000\n"
    end

    test "mixed ascii and unicode" do
      cmd = "echo \"Price: #{euro()}50 (#{approx()}\\$55)\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "Price: #{euro()}50 (#{approx()}$55)\n"
    end

    test "trademark and copyright" do
      cmd = "echo \"Product#{trademark()} #{copyright()}2024\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "Product#{trademark()} #{copyright()}2024\n"
    end
  end

  describe "unicode with variable expansion" do
    test "variable before unicode" do
      cmd = "T=42; echo \"$T" <> degree() <> "F\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "42#{degree()}F\n"
    end

    test "variable after unicode" do
      cmd = "X=test; echo \"" <> arrow_right() <> "$X" <> arrow_left() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{arrow_right()}test#{arrow_left()}\n"
    end

    test "unicode before and after variable" do
      cmd = "N=5; echo \"" <> star() <> "$N" <> star() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{star()}5#{star()}\n"
    end

    test "unicode in variable value" do
      cmd = "MSG=\"" <> hello_umlaut() <> "\"; echo \"$MSG\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{hello_umlaut()}\n"
    end

    test "multiple variables with unicode between" do
      cmd = "A=1; B=2; echo \"$A" <> arrow_right() <> "$B\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "1#{arrow_right()}2\n"
    end

    test "braced variable with unicode" do
      cmd = "X=val; echo \"" <> laquo() <> "${X}" <> raquo() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{laquo()}val#{raquo()}\n"
    end
  end

  describe "unicode in unquoted context" do
    test "unquoted unicode word" do
      cmd = "echo #{cafe()}"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{cafe()}\n"
    end

    test "multiple unquoted unicode words" do
      cmd = "echo #{hello_umlaut()} #{world_umlaut()}"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{hello_umlaut()} #{world_umlaut()}\n"
    end

    test "unicode in filename" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "echo \"content\" > /tmp/#{test_umlaut()}.txt")
      {result, _} = JustBash.exec(bash, "cat /tmp/#{test_umlaut()}.txt")
      assert result.exit_code == 0
      assert result.stdout == "content\n"
    end
  end

  describe "unicode in single-quoted strings" do
    test "single quoted unicode passes through" do
      cmd = "echo '" <> cafe() <> "'"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{cafe()}\n"
    end

    test "single quoted with special chars" do
      cmd = "echo '" <> arrow_right() <> "$X" <> arrow_left() <> "'"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      # Single quotes preserve $X literally
      assert result.stdout == "#{arrow_right()}$X#{arrow_left()}\n"
    end
  end

  describe "unicode in heredocs" do
    test "heredoc with unicode" do
      script = """
      cat << EOF
      Temperature: 42#{degree()}F
      Price: #{euro()}50
      EOF
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.exit_code == 0
      assert result.stdout == "Temperature: 42#{degree()}F\nPrice: #{euro()}50\n"
    end

    test "heredoc with variable and unicode" do
      script = """
      T=42
      cat << EOF
      It is $T#{degree()}F outside
      EOF
      """

      {result, _} = JustBash.exec(JustBash.new(), script)
      assert result.exit_code == 0
      assert result.stdout == "It is 42#{degree()}F outside\n"
    end
  end

  describe "unicode in command substitution" do
    test "command substitution result with unicode" do
      cmd = "echo \"Got: $(echo " <> cafe() <> ")\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "Got: #{cafe()}\n"
    end

    test "unicode around command substitution" do
      cmd = "echo \"" <> arrow_right() <> "$(echo test)" <> arrow_left() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{arrow_right()}test#{arrow_left()}\n"
    end

    test "nested with unicode" do
      cmd = "X=$(echo \"" <> star() <> "\"); echo \"Got: $X\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "Got: #{star()}\n"
    end
  end

  describe "unicode in parameter expansion" do
    test "string length with unicode" do
      # cafe() = "caf\u00E9" has 4 graphemes
      cmd = "X=" <> cafe() <> "; echo ${#X}"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "4\n"
    end

    test "string length with emoji" do
      # Single emoji is 1 grapheme (even though multi-byte)
      cmd = "X=" <> wave() <> "; echo ${#X}"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "1\n"
    end

    test "substring with unicode" do
      cmd = "X=" <> hello_umlaut() <> "; echo ${X:1:3}"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      # hello_umlaut = "hëllo", ${X:1:3} = "ëll"
      assert result.stdout == "\u00EBll\n"
    end

    test "default value with unicode" do
      cmd = "echo ${UNSET:-" <> default_val() <> "}"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{default_val()}\n"
    end

    test "pattern replacement with unicode" do
      cmd = "X=" <> cafe() <> "; echo ${X/" <> e_acute() <> "/e}"
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "cafe\n"
    end
  end

  describe "unicode in arithmetic" do
    test "unicode in echo around arithmetic" do
      cmd = "echo \"Result: $((1+2))" <> degree() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "Result: 3#{degree()}\n"
    end
  end

  describe "unicode edge cases" do
    test "empty string with unicode after" do
      cmd = "X=\"\"; echo \"$X" <> degree() <> "F\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{degree()}F\n"
    end

    test "only unicode character" do
      cmd = "echo \"" <> degree() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{degree()}\n"
    end

    test "unicode at string boundaries" do
      cmd = "echo \"" <> degree() <> "test" <> degree() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{degree()}test#{degree()}\n"
    end

    test "consecutive unicode characters" do
      cmd = "echo \"" <> degree() <> degree() <> degree() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{degree()}#{degree()}#{degree()}\n"
    end

    test "unicode with backslash escape" do
      # In bash, \\ inside double quotes becomes a single backslash
      cmd = "echo \"test\\\\" <> degree() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "test\\#{degree()}\n"
    end

    test "unicode with dollar escape" do
      # In bash, \$ inside double quotes becomes a literal $
      cmd = "echo \"cost: \\$50" <> euro() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "cost: $50#{euro()}\n"
    end

    test "long unicode string" do
      cmd = "echo \"" <> japanese_text() <> "\""
      {result, _} = JustBash.exec(JustBash.new(), cmd)
      assert result.exit_code == 0
      assert result.stdout == "#{japanese_text()}\n"
    end
  end
end
