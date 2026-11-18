defmodule JustBash.TextRegexTest do
  use ExUnit.Case, async: true

  alias JustBash.TextRegex

  describe "compile/2" do
    test "a UTF-8 pattern gets the Unicode options" do
      assert {:ok, regex} = TextRegex.compile("caf.", [:caseless])
      assert :unicode in regex.opts
      assert :ucp in regex.opts
      assert :caseless in regex.opts
    end

    test "a pattern that is not valid UTF-8 compiles for bytes" do
      assert {:ok, regex} = TextRegex.compile(<<"caf", 0xFF>>)
      refute :unicode in regex.opts
      assert Regex.match?(regex, <<"caf", 0xFF>>)
    end

    test "an invalid pattern is an error" do
      assert {:error, _} = TextRegex.compile("(")
    end
  end

  describe "for_subject/2" do
    test "keeps the regex for a UTF-8 subject" do
      regex = TextRegex.compile!("caf.$")
      assert TextRegex.for_subject(regex, "café") == regex
    end

    test "recompiles for bytes when the subject is not valid UTF-8" do
      regex = TextRegex.compile!("caf.$", [:caseless])
      byte_regex = TextRegex.for_subject(regex, <<"caf", 0xFF>>)

      refute :unicode in byte_regex.opts
      refute :ucp in byte_regex.opts
      assert :caseless in byte_regex.opts
    end
  end

  describe "matching" do
    test "dot is one character on UTF-8 and one byte otherwise" do
      regex = TextRegex.compile!("^caf.$")

      assert TextRegex.match?(regex, "café")
      assert TextRegex.match?(regex, <<"caf", 0xFF>>)
      assert TextRegex.run(regex, "café") == ["café"]
      assert TextRegex.scan(regex, <<"caf", 0xFF>>) == [[<<"caf", 0xFF>>]]
    end

    test "word characters include letters outside ASCII" do
      assert TextRegex.run(TextRegex.compile!("\\w+"), "naïve plan") == ["naïve"]
    end
  end
end
