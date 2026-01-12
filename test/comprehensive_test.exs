defmodule JustBash.ComprehensiveTest do
  @moduledoc """
  Comprehensive integration tests that verify exact output matching.
  These tests exercise multiple features together and verify complete correctness.
  """
  use ExUnit.Case, async: true

  describe "tilde expansion" do
    test "~ expands to HOME" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ~")
      assert result.stdout == "/home/user\n"
      assert result.exit_code == 0
    end

    test "~/path expands to HOME/path" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo ~/subdir/file.txt")
      assert result.stdout == "/home/user/subdir/file.txt\n"
      assert result.exit_code == 0
    end

    test "~ in middle of word is literal" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo foo~bar")
      assert result.stdout == "foo~bar\n"
    end

    test "cd ~ changes to home directory" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "cd /tmp")
      {_, bash} = JustBash.exec(bash, "cd ~")
      {result, _} = JustBash.exec(bash, "pwd")
      assert result.stdout == "/home/user\n"
    end

    test "tilde in assignment expands" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "mydir=~/data")
      {result, _} = JustBash.exec(bash, "echo $mydir")
      assert result.stdout == "/home/user/data\n"
    end
  end

  describe "for loop IFS splitting" do
    test "splits on custom IFS" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        items="a:b:c"
        IFS=:
        for i in $items; do echo "[$i]"; done
        """)

      assert result.stdout == "[a]\n[b]\n[c]\n"
      assert result.exit_code == 0
    end

    test "default IFS splits on whitespace" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        items="one two three"
        for i in $items; do echo "[$i]"; done
        """)

      assert result.stdout == "[one]\n[two]\n[three]\n"
    end

    test "quoted string not split" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        items="one two three"
        for i in "$items"; do echo "[$i]"; done
        """)

      assert result.stdout == "[one two three]\n"
    end

    test "IFS with multiple characters" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        data="a,b;c"
        IFS=',;'
        for x in $data; do echo "($x)"; done
        """)

      assert result.stdout == "(a)\n(b)\n(c)\n"
    end
  end

  describe "sed backrefs with global flag" do
    test "backref \\1 works with g flag" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'cat dog cat dog' | sed 's/\\(cat\\)/[\\1]/g'")
      assert result.stdout == "[cat] dog [cat] dog\n"
      assert result.exit_code == 0
    end

    test "multiple backrefs with g flag" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "echo 'ab ab ab' | sed 's/\\(a\\)\\(b\\)/\\2\\1/g'")

      assert result.stdout == "ba ba ba\n"
    end

    test "backref with ampersand and g flag" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo 'foo bar foo' | sed 's/foo/[&]/g'")
      assert result.stdout == "[foo] bar [foo]\n"
    end
  end

  describe "source command" do
    test "source loads variables from file" do
      bash = JustBash.new(files: %{"/script.sh" => "LOADED_VAR=hello\n"})

      {result, _} =
        JustBash.exec(bash, """
        source /script.sh
        echo $LOADED_VAR
        """)

      assert result.stdout == "hello\n"
      assert result.exit_code == 0
    end

    test "dot command loads variables from file" do
      bash = JustBash.new(files: %{"/script.sh" => "X=42\nY=100\n"})

      {result, _} =
        JustBash.exec(bash, """
        . /script.sh
        echo $((X + Y))
        """)

      assert result.stdout == "142\n"
    end

    test "source executes commands" do
      bash =
        JustBash.new(
          files: %{
            "/setup.sh" => """
            echo "Setting up..."
            export APP_ENV=production
            """
          }
        )

      {result, bash} = JustBash.exec(bash, "source /setup.sh")
      assert result.stdout == "Setting up...\n"
      assert bash.env["APP_ENV"] == "production"
    end

    test "source with nonexistent file fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "source /nonexistent.sh")
      assert result.exit_code != 0
      assert result.stderr =~ "not found" or result.stderr =~ "No such file"
    end
  end

  describe "assign default ${VAR:=default}" do
    test "assigns default when unset" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        unset UNSET 2>/dev/null
        echo "${UNSET:=mydefault}"
        echo "now: $UNSET"
        """)

      assert result.stdout == "mydefault\nnow: mydefault\n"
    end

    test "assigns default when empty with colon" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        EMPTY=""
        echo "${EMPTY:=filled}"
        echo "now: $EMPTY"
        """)

      assert result.stdout == "filled\nnow: filled\n"
    end

    test "does not assign when already set" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        EXISTING=original
        echo "${EXISTING:=ignored}"
        echo "still: $EXISTING"
        """)

      assert result.stdout == "original\nstill: original\n"
    end

    test "without colon only checks unset, not empty" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        EMPTY=""
        echo "[${EMPTY=default}]"
        echo "still empty: [$EMPTY]"
        """)

      assert result.stdout == "[]\nstill empty: []\n"
    end
  end

  describe "complex pipelines" do
    test "sort | head | tail pipeline" do
      bash =
        JustBash.new(
          files: %{
            "/data.txt" => "3 apple\n1 banana\n2 cherry\n4 date\n"
          }
        )

      # After sort -n: 1 banana, 2 cherry, 3 apple, 4 date
      # After head -3: 1 banana, 2 cherry, 3 apple
      # After tail -1: 3 apple
      {result, _} = JustBash.exec(bash, "sort -n /data.txt | head -3 | tail -1")
      assert result.stdout == "3 apple\n"
    end

    test "grep | wc pipeline" do
      bash =
        JustBash.new(
          files: %{
            "/log.txt" => "INFO started\nERROR failed\nINFO running\nERROR crashed\nINFO done\n"
          }
        )

      {result, _} = JustBash.exec(bash, "grep ERROR /log.txt | wc -l")
      assert String.trim(result.stdout) == "2"
    end

    test "cat | tr | sort | uniq pipeline" do
      bash =
        JustBash.new(
          files: %{
            "/words.txt" => "HELLO\nworld\nHELLO\nWorld\nhello\n"
          }
        )

      {result, _} = JustBash.exec(bash, "cat /words.txt | tr 'A-Z' 'a-z' | sort | uniq")
      assert result.stdout == "hello\nworld\n"
    end
  end

  describe "nested expansions" do
    test "variable in variable name (indirect)" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        greeting=hello
        varname=greeting
        echo ${!varname}
        """)

      assert result.stdout == "hello\n"
    end

    test "arithmetic with variables" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        x=10
        y=20
        echo $((x + y * 2))
        """)

      assert result.stdout == "50\n"
    end

    test "nested command substitution" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo $(echo $(echo deep))")
      assert result.stdout == "deep\n"
    end

    test "parameter expansion with command substitution default" do
      bash = JustBash.new()
      cmd = "echo \"${UNSET:-$(echo fallback)}\""
      {result, _} = JustBash.exec(bash, cmd)
      assert result.stdout == "fallback\n"
    end

    test "length of computed value" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        prefix="HEL"
        suffix="LO"
        full="${prefix}${suffix}"
        echo ${#full}
        """)

      assert result.stdout == "5\n"
    end
  end

  describe "edge cases and combining features" do
    test "empty IFS prevents splitting" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        data="a b c"
        IFS=''
        for x in $data; do echo "[$x]"; done
        """)

      assert result.stdout == "[a b c]\n"
    end

    test "set -e with pipeline and pipefail" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        set -eo pipefail
        echo before
        true | false | true
        echo after
        """)

      assert result.stdout == "before\n"
      assert result.exit_code == 1
    end

    test "brace expansion in echo" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo file{1,2,3}.txt")
      assert result.stdout == "file1.txt file2.txt file3.txt\n"
    end

    test "complex case statement" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        for ext in jpg png gif txt; do
          case $ext in
            jpg|png|gif) echo "$ext is image" ;;
            txt) echo "$ext is text" ;;
            *) echo "$ext is unknown" ;;
          esac
        done
        """)

      assert result.stdout == "jpg is image\npng is image\ngif is image\ntxt is text\n"
    end

    test "function with positional parameters" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        greet() {
          echo "Hello, $1!"
        }
        greet World
        greet Elixir
        """)

      assert result.stdout == "Hello, World!\nHello, Elixir!\n"
    end

    test "arithmetic in test condition" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        count=5
        if [ $((count * 2)) -gt 8 ]; then
          echo "big"
        else
          echo "small"
        fi
        """)

      assert result.stdout == "big\n"
    end

    test "heredoc with variable expansion" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        name=World
        cat <<EOF
        Hello, $name!
        Today is a good day.
        EOF
        """)

      assert result.stdout == "Hello, World!\nToday is a good day.\n"
    end

    test "while loop with counter" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        i=0
        while [ $i -lt 3 ]; do
          echo "iteration $i"
          i=$((i + 1))
        done
        """)

      assert result.stdout == "iteration 0\niteration 1\niteration 2\n"
    end

    test "until loop" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        x=3
        until [ $x -le 0 ]; do
          echo "x is $x"
          x=$((x - 1))
        done
        """)

      assert result.stdout == "x is 3\nx is 2\nx is 1\n"
    end
  end
end
