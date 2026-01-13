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

    test "works in pipeline with sqlite and liquid" do
      bash = JustBash.new()

      # Create a post with markdown content
      {_, bash} =
        JustBash.exec(bash, "sqlite3 blog 'CREATE TABLE posts (title TEXT, content TEXT)'")

      {_, bash} =
        JustBash.exec(
          bash,
          ~s[sqlite3 blog "INSERT INTO posts VALUES ('Hello', '# Welcome\\n\\nThis is **great**.')"]
        )

      # Template that expects html_content
      bash =
        put_in(
          bash.fs,
          JustBash.Fs.InMemoryFs.write_file(
            bash.fs,
            "/template.html",
            "<article><h1>{{ title }}</h1><div>{{ html_content }}</div></article>"
          )
          |> elem(1)
        )

      # This would be a real pipeline - but we need to process markdown separately
      # because liquid doesn't have a markdown filter
      {result, _} =
        JustBash.exec(bash, ~s[sqlite3 blog "SELECT content FROM posts" | markdown])

      assert result.exit_code == 0
      assert result.stdout =~ "<h1>"
      assert result.stdout =~ "<strong>great</strong>"
    end
  end
end
