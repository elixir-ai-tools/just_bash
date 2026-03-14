defmodule JustBash.Shell.RedirectionsTest do
  use ExUnit.Case, async: true

  describe "redirections" do
    test "redirect stdout to file with >" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "echo hello > /output.txt")
      assert result.stdout == ""

      {result2, _} = JustBash.exec(bash, "cat /output.txt")
      assert result2.stdout == "hello\n"
    end

    test "append stdout to file with >>" do
      bash = JustBash.new(files: %{"/output.txt" => "first\n"})
      {result, bash} = JustBash.exec(bash, "echo second >> /output.txt")
      assert result.stdout == ""

      {result2, _} = JustBash.exec(bash, "cat /output.txt")
      assert result2.stdout == "first\nsecond\n"
    end

    test "redirect to /dev/null" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello > /dev/null")
      assert result.stdout == ""
    end

    test "multiple redirections" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "echo hello > /out.txt")
      {result2, bash2} = JustBash.exec(bash, "echo world >> /out.txt")
      assert result.stdout == ""
      assert result2.stdout == ""

      {result3, _} = JustBash.exec(bash2, "cat /out.txt")
      assert result3.stdout == "hello\nworld\n"
    end

    test "redirect with variable expansion" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "FILE=/output.txt")
      {result, bash} = JustBash.exec(bash, "echo content > $FILE")
      assert result.stdout == ""

      {result2, _} = JustBash.exec(bash, "cat $FILE")
      assert result2.stdout == "content\n"
    end

    test "stdin redirection after stdout redirection" do
      bash = JustBash.new(files: %{"/in.txt" => "hello"})
      {_, bash} = JustBash.exec(bash, "cat > /out.txt < /in.txt")
      {result, _} = JustBash.exec(bash, "cat /out.txt")
      assert result.stdout == "hello"
    end

    test "stdin redirection before stdout redirection" do
      bash = JustBash.new(files: %{"/in.txt" => "hello"})
      {_, bash} = JustBash.exec(bash, "cat < /in.txt > /out.txt")
      {result, _} = JustBash.exec(bash, "cat /out.txt")
      assert result.stdout == "hello"
    end
  end

  describe "heredoc with compound commands" do
    test "while loop with heredoc reads all lines" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        while read -r line; do
          echo "GOT: $line"
        done <<EOF
        hello
        world
        EOF
        """)

      assert result.stdout =~ "GOT: hello"
      assert result.stdout =~ "GOT: world"
    end

    test "while loop with heredoc preserves variable changes" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        count=0
        while read -r line; do
          count=$((count + 1))
        done <<LINES
        alpha
        beta
        gamma
        LINES
        echo "count=$count"
        """)

      assert result.stdout == "count=3\n"
    end

    test "for loop with heredoc output redirection" do
      bash = JustBash.new()

      {result, bash} =
        JustBash.exec(bash, """
        for i in 1 2 3; do
          echo "line $i"
        done > /tmp/out.txt
        """)

      assert result.stdout == ""
      {result, _} = JustBash.exec(bash, "cat /tmp/out.txt")
      assert result.stdout =~ "line 1"
      assert result.stdout =~ "line 3"
    end

    test "while read loop with heredoc populates associative array" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, """
        declare -A config
        while IFS="=" read -r key value; do
          config["$key"]="$value"
        done <<EOF
        host=localhost
        port=5432
        EOF
        echo "host=${config["host"]}"
        echo "port=${config["port"]}"
        """)

      assert result.stdout == "host=localhost\nport=5432\n"
    end
  end
end
