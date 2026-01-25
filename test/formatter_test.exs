defmodule JustBash.FormatterTest do
  use ExUnit.Case, async: true

  alias JustBash.Formatter

  describe "format/1 simple commands" do
    test "formats echo command" do
      assert {:ok, formatted} = JustBash.format("echo hello")
      assert formatted == "echo hello"
    end

    test "formats command with multiple args" do
      assert {:ok, formatted} = JustBash.format("echo hello world")
      assert formatted == "echo hello world"
    end

    test "formats assignment" do
      assert {:ok, formatted} = JustBash.format("VAR=value")
      assert formatted == "VAR=value"
    end

    test "formats assignment with command" do
      assert {:ok, formatted} = JustBash.format("VAR=value echo $VAR")
      assert formatted == "VAR=value echo $VAR"
    end

    test "formats append assignment" do
      assert {:ok, formatted} = JustBash.format("VAR+=more")
      assert formatted == "VAR+=more"
    end
  end

  describe "format/1 quoting" do
    test "formats single-quoted string" do
      assert {:ok, formatted} = JustBash.format("echo 'hello world'")
      assert formatted == "echo 'hello world'"
    end

    test "formats double-quoted string" do
      assert {:ok, formatted} = JustBash.format("echo \"hello world\"")
      assert formatted == "echo \"hello world\""
    end

    test "formats double-quoted string with variable" do
      assert {:ok, formatted} = JustBash.format("echo \"hello $NAME\"")
      assert formatted == "echo \"hello $NAME\""
    end
  end

  describe "format/1 variable expansion" do
    test "formats simple variable" do
      assert {:ok, formatted} = JustBash.format("echo $VAR")
      assert formatted == "echo $VAR"
    end

    test "formats braced variable (normalized to simple form)" do
      # ${VAR} and $VAR parse to the same AST, formatter outputs simpler form
      assert {:ok, formatted} = JustBash.format("echo ${VAR}")
      assert formatted == "echo $VAR"
    end

    test "formats default value expansion" do
      assert {:ok, formatted} = JustBash.format("echo ${VAR:-default}")
      assert formatted == "echo ${VAR:-default}"
    end

    test "formats length expansion" do
      assert {:ok, formatted} = JustBash.format("echo ${#VAR}")
      assert formatted == "echo ${#VAR}"
    end

    test "formats substring expansion" do
      assert {:ok, formatted} = JustBash.format("echo ${VAR:0:5}")
      assert formatted == "echo ${VAR:0:5}"
    end

    test "formats pattern removal" do
      assert {:ok, formatted} = JustBash.format("echo ${VAR#pattern}")
      assert formatted == "echo ${VAR#pattern}"
    end

    test "formats pattern replacement" do
      assert {:ok, formatted} = JustBash.format("echo ${VAR/old/new}")
      assert formatted == "echo ${VAR/old/new}"
    end
  end

  describe "format/1 command substitution" do
    test "formats $() style" do
      assert {:ok, formatted} = JustBash.format("echo $(date)")
      assert formatted == "echo $(date)"
    end

    test "formats backtick style" do
      assert {:ok, formatted} = JustBash.format("echo `date`")
      assert formatted == "echo `date`"
    end
  end

  describe "format/1 arithmetic" do
    test "formats arithmetic expansion" do
      assert {:ok, formatted} = JustBash.format("echo $((1 + 2))")
      assert formatted == "echo $(( 1 + 2 ))"
    end

    test "formats arithmetic command" do
      assert {:ok, formatted} = JustBash.format("(( x = 5 ))")
      assert formatted == "(( x = 5 ))"
    end
  end

  describe "format/1 pipelines" do
    test "formats simple pipeline" do
      assert {:ok, formatted} = JustBash.format("cat file | grep pattern")
      assert formatted == "cat file | grep pattern"
    end

    test "formats multi-stage pipeline" do
      assert {:ok, formatted} = JustBash.format("cat file | grep x | sort | uniq")
      assert formatted == "cat file | grep x | sort | uniq"
    end

    test "formats negated pipeline" do
      assert {:ok, formatted} = JustBash.format("! grep pattern file")
      assert formatted == "! grep pattern file"
    end
  end

  describe "format/1 compound commands" do
    test "formats && operator" do
      assert {:ok, formatted} = JustBash.format("cmd1 && cmd2")
      assert formatted == "cmd1 && cmd2"
    end

    test "formats || operator" do
      assert {:ok, formatted} = JustBash.format("cmd1 || cmd2")
      assert formatted == "cmd1 || cmd2"
    end

    test "formats background command" do
      assert {:ok, formatted} = JustBash.format("cmd &")
      assert formatted == "cmd &"
    end
  end

  describe "format/1 if statements" do
    test "formats simple if" do
      input = "if true; then echo yes; fi"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "if true; then\n  echo yes\nfi"
    end

    test "formats if-else" do
      input = "if true; then echo yes; else echo no; fi"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "if true; then\n  echo yes\nelse\n  echo no\nfi"
    end

    test "formats if-elif-else" do
      input = "if test1; then echo 1; elif test2; then echo 2; else echo 3; fi"
      assert {:ok, formatted} = JustBash.format(input)

      expected = """
      if test1; then
        echo 1
      elif test2; then
        echo 2
      else
        echo 3
      fi\
      """

      assert formatted == expected
    end
  end

  describe "format/1 for loops" do
    test "formats for loop" do
      input = "for i in 1 2 3; do echo $i; done"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "for i in 1 2 3; do\n  echo $i\ndone"
    end

    test "formats for loop without word list" do
      input = "for i; do echo $i; done"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "for i; do\n  echo $i\ndone"
    end

    # C-style for loops are not yet supported by the parser
    # test "formats C-style for loop" do
    #   input = "for ((i=0; i<10; i++)); do echo $i; done"
    #   assert {:ok, formatted} = JustBash.format(input)
    #   assert formatted == "for ((i = 0; i < 10; i++)); do\n  echo $i\ndone"
    # end
  end

  describe "format/1 while/until loops" do
    test "formats while loop" do
      input = "while true; do echo loop; done"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "while true; do\n  echo loop\ndone"
    end

    test "formats until loop" do
      input = "until false; do echo loop; done"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "until false; do\n  echo loop\ndone"
    end
  end

  describe "format/1 case statements" do
    test "formats case statement" do
      input = "case $x in a) echo a;; b) echo b;; esac"
      assert {:ok, formatted} = JustBash.format(input)

      expected = """
      case $x in
        a)
          echo a
        ;;
        b)
          echo b
        ;;
      esac\
      """

      assert formatted == expected
    end

    test "formats case with multiple patterns" do
      input = "case $x in a|b) echo ab;; esac"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted =~ "a | b)"
    end
  end

  describe "format/1 subshell and group" do
    test "formats subshell" do
      assert {:ok, formatted} = JustBash.format("( echo hello )")
      assert formatted == "( echo hello )"
    end

    test "formats group" do
      assert {:ok, formatted} = JustBash.format("{ echo hello; }")
      assert formatted == "{ echo hello; }"
    end
  end

  describe "format/1 functions" do
    test "formats function definition" do
      input = "myfunc() { echo hello; }"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "myfunc() { echo hello; }"
    end
  end

  describe "format/1 redirections" do
    test "formats output redirection" do
      assert {:ok, formatted} = JustBash.format("echo hello > file.txt")
      assert formatted == "echo hello >file.txt"
    end

    test "formats append redirection" do
      assert {:ok, formatted} = JustBash.format("echo hello >> file.txt")
      assert formatted == "echo hello >>file.txt"
    end

    test "formats input redirection" do
      assert {:ok, formatted} = JustBash.format("cat < file.txt")
      assert formatted == "cat <file.txt"
    end

    test "formats stderr redirection" do
      assert {:ok, formatted} = JustBash.format("cmd 2>&1")
      assert formatted == "cmd 2>&1"
    end

    test "formats here-string" do
      # Single quotes are not preserved in AST (they just quote the literal)
      assert {:ok, formatted} = JustBash.format("cat <<< 'hello'")
      assert formatted == "cat <<<hello"
    end
  end

  describe "format/1 conditional expressions" do
    test "formats [[ ]] expression" do
      assert {:ok, formatted} = JustBash.format("[[ -f file ]]")
      assert formatted == "[[ -f file ]]"
    end

    test "formats [[ ]] with comparison" do
      assert {:ok, formatted} = JustBash.format("[[ $a == $b ]]")
      assert formatted == "[[ $a == $b ]]"
    end
  end

  describe "format/1 brace expansion" do
    test "formats brace expansion" do
      assert {:ok, formatted} = JustBash.format("echo {a,b,c}")
      assert formatted == "echo {a,b,c}"
    end

    test "formats sequence brace expansion" do
      assert {:ok, formatted} = JustBash.format("echo {1..5}")
      assert formatted == "echo {1..5}"
    end
  end

  describe "format/1 tilde expansion" do
    test "formats tilde" do
      assert {:ok, formatted} = JustBash.format("cd ~")
      assert formatted == "cd ~"
    end

    test "formats tilde with user" do
      assert {:ok, formatted} = JustBash.format("cd ~user")
      assert formatted == "cd ~user"
    end
  end

  describe "format/1 with custom indent" do
    test "uses custom indent string" do
      input = "if true; then echo yes; fi"
      assert {:ok, formatted} = JustBash.format(input, indent: "\t")
      assert formatted == "if true; then\n\techo yes\nfi"
    end

    test "uses 4-space indent" do
      input = "if true; then echo yes; fi"
      assert {:ok, formatted} = JustBash.format(input, indent: "    ")
      assert formatted == "if true; then\n    echo yes\nfi"
    end
  end

  describe "format!/1" do
    test "returns formatted string on success" do
      assert JustBash.format!("echo hello") == "echo hello"
    end

    test "raises on parse error" do
      assert_raise RuntimeError, ~r/error/, fn ->
        JustBash.format!("echo 'unterminated")
      end
    end
  end

  describe "Formatter.format/2 direct usage" do
    test "formats AST directly" do
      {:ok, ast} = JustBash.parse("echo hello")
      assert Formatter.format(ast) == "echo hello"
    end
  end

  describe "format/1 multiple statements" do
    test "formats multiple statements" do
      input = "echo first\necho second"
      assert {:ok, formatted} = JustBash.format(input)
      assert formatted == "echo first\necho second"
    end
  end

  describe "format/1 nested structures" do
    test "formats nested if in for" do
      input = "for i in 1 2; do if true; then echo $i; fi; done"
      assert {:ok, formatted} = JustBash.format(input)

      expected = """
      for i in 1 2; do
        if true; then
          echo $i
        fi
      done\
      """

      assert formatted == expected
    end
  end
end
