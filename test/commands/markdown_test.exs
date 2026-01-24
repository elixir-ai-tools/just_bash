defmodule JustBash.Commands.MarkdownTest do
  use ExUnit.Case, async: true

  describe "markdown command" do
    test "converts heading" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '# Hello' | markdown")

      assert result.exit_code == 0
      assert result.stdout =~ "<h1>"
      assert result.stdout =~ "Hello"
    end

    test "converts bold and italic" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '**bold** and *italic*' | markdown")

      assert result.exit_code == 0
      assert result.stdout =~ "<strong>bold</strong>"
      assert result.stdout =~ "<em>italic</em>"
    end

    test "converts links" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '[link](https://example.com)' | markdown")

      assert result.exit_code == 0
      assert result.stdout =~ ~s(<a href="https://example.com">link</a>)
    end

    test "converts code blocks" do
      bash =
        JustBash.new(
          files: %{
            "/doc.md" => """
            ```elixir
            def hello, do: :world
            ```
            """
          }
        )

      {result, _} = JustBash.exec(bash, "markdown /doc.md")

      assert result.exit_code == 0
      assert result.stdout =~ "<code"
      assert result.stdout =~ "def hello"
    end

    test "converts lists" do
      bash = JustBash.new()

      md = "- one\\n- two\\n- three"
      {result, _} = JustBash.exec(bash, "echo -e '#{md}' | markdown")

      assert result.exit_code == 0
      assert result.stdout =~ "<ul>"
      assert result.stdout =~ "<li>"
    end

    test "reads from file" do
      bash =
        JustBash.new(files: %{"/README.md" => "# My Project\n\nThis is cool."})

      {result, _} = JustBash.exec(bash, "markdown /README.md")

      assert result.exit_code == 0
      assert result.stdout =~ "<h1>"
      assert result.stdout =~ "My Project"
    end

    test "md alias works" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '## Heading' | md")

      assert result.exit_code == 0
      assert result.stdout =~ "<h2>"
    end

    test "GFM tables" do
      bash = JustBash.new()

      md = "| a | b |\\n|---|---|\\n| 1 | 2 |"
      {result, _} = JustBash.exec(bash, "echo -e '#{md}' | markdown")

      assert result.exit_code == 0
      assert result.stdout =~ "<table>"
    end

    test "GFM strikethrough" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '~~deleted~~' | markdown")

      assert result.exit_code == 0
      assert result.stdout =~ "<del>deleted</del>"
    end

    test "--help shows usage" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "markdown --help")

      assert result.exit_code == 0
      assert result.stdout =~ "Usage:"
      assert result.stdout =~ "--gfm"
    end

    test "error on missing file" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "markdown /nonexistent.md")

      assert result.exit_code == 1
      assert result.stderr =~ "cannot read"
    end
  end
end
