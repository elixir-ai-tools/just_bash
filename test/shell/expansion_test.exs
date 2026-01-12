defmodule JustBash.Shell.ExpansionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for shell expansion features:
  - Brace expansion: {a,b,c}, {1..5}, {a..z}
  - Nested arithmetic: $((1 + (2 * 3)))
  - Nested parameter expansion: ${x:-${y:-default}}
  - Glob expansion: *.txt, /path/*
  """

  describe "brace expansion - list form {a,b,c}" do
    test "simple list expansion" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a,b,c}")
      assert result.stdout == "a b c\n"
    end

    test "two element list" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {x,y}")
      assert result.stdout == "x y\n"
    end

    test "list with empty element at end" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a,b,}")
      assert result.stdout == "a b \n"
    end

    test "list with empty element at start" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {,a,b}")
      assert result.stdout == " a b\n"
    end

    test "list with prefix" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo pre{a,b,c}")
      assert result.stdout == "prea preb prec\n"
    end

    test "list with suffix" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a,b,c}post")
      assert result.stdout == "apost bpost cpost\n"
    end

    test "list with prefix and suffix" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo pre{a,b,c}post")
      assert result.stdout == "preapost prebpost precpost\n"
    end

    test "file extension pattern" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo file.{txt,md,json}")
      assert result.stdout == "file.txt file.md file.json\n"
    end

    test "nested brace expansion" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a,{b,c}}")
      assert result.stdout == "a b c\n"
    end

    test "deeply nested brace expansion" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a,{b,{c,d}}}")
      assert result.stdout == "a b c d\n"
    end

    test "multiple brace expansions in sequence" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a,b}{1,2}")
      assert result.stdout == "a1 a2 b1 b2\n"
    end

    test "three brace expansions" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a,b}{1,2}{x,y}")
      assert result.stdout == "a1x a1y a2x a2y b1x b1y b2x b2y\n"
    end
  end

  describe "brace expansion - numeric range {1..5}" do
    test "ascending numeric range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {1..5}")
      assert result.stdout == "1 2 3 4 5\n"
    end

    test "descending numeric range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {5..1}")
      assert result.stdout == "5 4 3 2 1\n"
    end

    test "single element range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {3..3}")
      assert result.stdout == "3\n"
    end

    test "negative to positive range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {-2..2}")
      assert result.stdout == "-2 -1 0 1 2\n"
    end

    test "range with prefix" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo file{1..3}.txt")
      assert result.stdout == "file1.txt file2.txt file3.txt\n"
    end

    test "range combined with list" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {1..3}{a,b}")
      assert result.stdout == "1a 1b 2a 2b 3a 3b\n"
    end
  end

  describe "brace expansion - character range {a..z}" do
    test "ascending character range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a..e}")
      assert result.stdout == "a b c d e\n"
    end

    test "descending character range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {e..a}")
      assert result.stdout == "e d c b a\n"
    end

    test "uppercase character range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {A..E}")
      assert result.stdout == "A B C D E\n"
    end

    test "single character range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {x..x}")
      assert result.stdout == "x\n"
    end
  end

  describe "brace expansion - non-expansion patterns" do
    test "single element is not expanded" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {a}")
      assert result.stdout == "{a}\n"
    end

    test "empty braces are literal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo {}")
      assert result.stdout == "{}\n"
    end

    test "quoted braces are literal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo \"{a,b,c}\"")
      assert result.stdout == "{a,b,c}\n"
    end

    test "single quoted braces are literal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo '{a,b,c}'")
      assert result.stdout == "{a,b,c}\n"
    end
  end

  describe "brace expansion in for loops" do
    test "for loop with numeric range" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "for i in {1..3}; do echo $i; done")
      assert result.stdout == "1\n2\n3\n"
    end

    test "for loop with list expansion" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "for x in {a,b,c}; do echo $x; done")
      assert result.stdout == "a\nb\nc\n"
    end

    test "for loop with combined expansion" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "for f in file{1,2}.txt; do echo $f; done")
      assert result.stdout == "file1.txt\nfile2.txt\n"
    end
  end

  describe "nested arithmetic expansion" do
    test "simple nested parentheses" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 + (2 * 3)))")
      assert result.stdout == "7\n"
    end

    test "double nested parentheses" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 + (2 + (3 + 4))))")
      assert result.stdout == "10\n"
    end

    test "triple nested parentheses" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((((1 + 2)) * 3))")
      assert result.stdout == "9\n"
    end

    test "complex nested expression" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(((2 + 3) * (4 + 5)))")
      assert result.stdout == "45\n"
    end

    test "nested with variables" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "x=5; y=3; echo $(((x + y) * 2))")
      assert result.stdout == "16\n"
    end

    test "deeply nested arithmetic" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 + (2 * (3 + (4 * 5)))))")
      assert result.stdout == "47\n"
    end
  end

  describe "nested parameter expansion" do
    test "nested default value" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ${x:-${y:-default}}")
      assert result.stdout == "default\n"
    end

    test "nested default with outer set" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "x=outer; echo ${x:-${y:-default}}")
      assert result.stdout == "outer\n"
    end

    test "nested default with inner set" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "y=inner; echo ${x:-${y:-default}}")
      assert result.stdout == "inner\n"
    end

    test "triple nested default" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ${a:-${b:-${c:-deep}}}")
      assert result.stdout == "deep\n"
    end

    test "nested with different operators" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "x=hello; echo ${x:+${x}world}")
      assert result.stdout == "helloworld\n"
    end
  end

  describe "glob expansion" do
    test "star glob matches files" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "a",
            "/data/b.txt" => "b",
            "/data/c.log" => "c"
          }
        )

      bash = %{bash | cwd: "/data"}
      {result, _} = JustBash.exec(bash, "echo *.txt")
      # Should match a.txt and b.txt (sorted)
      assert result.stdout == "a.txt b.txt\n"
    end

    test "star glob with path" do
      bash =
        JustBash.new(
          files: %{
            "/data/a.txt" => "a",
            "/data/b.txt" => "b"
          }
        )

      {result, _} = JustBash.exec(bash, "echo /data/*.txt")
      assert result.stdout == "/data/a.txt /data/b.txt\n"
    end

    test "glob with no matches returns pattern" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo /nonexistent/*.xyz")
      assert result.stdout == "/nonexistent/*.xyz\n"
    end

    test "question mark glob" do
      bash =
        JustBash.new(
          files: %{
            "/data/a1.txt" => "",
            "/data/a2.txt" => "",
            "/data/a10.txt" => ""
          }
        )

      bash = %{bash | cwd: "/data"}
      {result, _} = JustBash.exec(bash, "echo a?.txt")
      assert result.stdout == "a1.txt a2.txt\n"
    end

    test "glob in for loop" do
      bash =
        JustBash.new(
          files: %{
            "/data/x.txt" => "x",
            "/data/y.txt" => "y"
          }
        )

      bash = %{bash | cwd: "/data"}
      {result, _} = JustBash.exec(bash, "for f in *.txt; do echo $f; done")
      assert result.stdout == "x.txt\ny.txt\n"
    end

    test "quoted glob is literal" do
      bash = JustBash.new(files: %{"/data/a.txt" => ""})
      bash = %{bash | cwd: "/data"}
      {result, _} = JustBash.exec(bash, "echo \"*.txt\"")
      assert result.stdout == "*.txt\n"
    end
  end

  describe "combined expansions" do
    test "brace expansion with variable" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ext=txt; echo file.{$ext,md}")
      assert result.stdout == "file.txt file.md\n"
    end

    test "brace and arithmetic" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $((1 + 2)) {a,b}")
      assert result.stdout == "3 a b\n"
    end

    test "brace and glob - brace first then glob" do
      bash =
        JustBash.new(
          files: %{
            "/data/file1.txt" => "",
            "/data/file2.txt" => ""
          }
        )

      bash = %{bash | cwd: "/data"}
      {result, _} = JustBash.exec(bash, "echo file{1,2}.txt")
      assert result.stdout == "file1.txt file2.txt\n"
    end
  end
end
