defmodule JustBash.Shell.HeredocMultibyteTest do
  use ExUnit.Case, async: true

  describe "heredoc with multi-byte characters" do
    test "heredoc with emoji in content" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > /tmp/emoji.txt
        Hello 🐾 World ❤️
        EOF
        cat /tmp/emoji.txt
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "🐾"
      assert result.stdout =~ "❤️"
    end

    test "large heredoc with mixed emoji and HTML" do
      bash = JustBash.new()
      paragraphs = String.duplicate("<p>Paragraph with emoji 🐾 and ❤️ and 🎉</p>\n", 50)

      html = """
      <!DOCTYPE html>
      <html><head><title>Test 🐾</title></head>
      <body>
      #{paragraphs}\
      </body></html>
      """

      command = "cat << 'EOF' > /tmp/large.html\n#{html}EOF\nwc -c /tmp/large.html"
      {result, _bash} = JustBash.exec(bash, command)
      assert result.exit_code == 0
    end

    test "heredoc with CJK characters" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > /tmp/cjk.txt
        日本語テスト 中文测试 한국어
        EOF
        cat /tmp/cjk.txt
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "日本語"
    end

    test "heredoc content is not lost (files_written populated)" do
      bash = JustBash.new()

      {result, bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > myfile.txt
        This content must not be silently dropped.
        Second line here.
        EOF
        """)

      assert result.exit_code == 0
      {:ok, content} = JustBash.Fs.read_file(bash.fs, "/home/user/myfile.txt")
      assert content =~ "must not be silently dropped"
    end

    test "multiple heredocs with emoji in single command" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF1' > /tmp/a.txt
        File A 🐾
        EOF1
        cat << 'EOF2' > /tmp/b.txt
        File B ❤️
        EOF2
        cat /tmp/a.txt /tmp/b.txt
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "🐾"
      assert result.stdout =~ "❤️"
    end
  end

  describe "heredoc with unmatched quotes in body" do
    test "heredoc body with apostrophes (unmatched single quotes)" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > /tmp/test.txt
        It's a beautiful day, don't you think?
        Let's go!
        EOF
        cat /tmp/test.txt
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "It's a beautiful day"
      assert result.stdout =~ "Let's go!"
    end

    test "heredoc body with HTML containing unmatched quotes" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > /tmp/test.html
        <div class="test">It's working</div>
        <p>She said "hello" and he said 'goodbye'</p>
        EOF
        cat /tmp/test.html
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "It's working"
    end

    test "heredoc body with unmatched double quotes" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > /tmp/test.txt
        She said "hello
        and then left
        EOF
        cat /tmp/test.txt
        """)

      assert result.exit_code == 0
      assert result.stdout =~ ~S(She said "hello)
    end

    test "heredoc body with backticks" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > /tmp/test.md
        Use `code` and ``double backticks``
        Unmatched ` backtick here
        EOF
        cat /tmp/test.md
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "Unmatched ` backtick here"
    end

    test "production-like HTML with emoji and quotes" do
      bash = JustBash.new()

      {result, _bash} =
        JustBash.exec(bash, ~S"""
        cat << 'EOF' > /tmp/index.html
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>Paws & Hearts 🐾</title>
          <style>
            body { font-family: 'Arial', sans-serif; color: #333; }
            h1::before { content: '🐾 '; }
          </style>
        </head>
        <body>
          <h1>Welcome to Paws & Hearts ❤️</h1>
          <p>It's a wonderful place for pets!</p>
          <p>Don't miss our special offers 🎉</p>
          <script>
            const msg = "Hello World";
            console.log(`Welcome! ${msg}`);
          </script>
        </body>
        </html>
        EOF
        cat /tmp/index.html
        """)

      assert result.exit_code == 0
      assert result.stdout =~ "Paws & Hearts 🐾"
      assert result.stdout =~ "It's a wonderful place"
    end
  end
end
