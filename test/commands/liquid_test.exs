defmodule JustBash.Commands.LiquidTest do
  use ExUnit.Case, async: true

  alias JustBash.Fs.InMemoryFs

  describe "liquid command" do
    test "renders simple variable" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "echo '{\"name\": \"World\"}' | liquid -e 'Hello, {{ name }}!'")

      assert result.exit_code == 0
      assert result.stdout == "Hello, World!"
    end

    test "renders from template file" do
      bash =
        JustBash.new(
          files: %{
            "/templates/greeting.html" => "<h1>Hello, {{ name }}!</h1>"
          }
        )

      {result, _} =
        JustBash.exec(bash, "echo '{\"name\": \"Alice\"}' | liquid /templates/greeting.html")

      assert result.exit_code == 0
      assert result.stdout == "<h1>Hello, Alice!</h1>"
    end

    test "renders with data file" do
      bash =
        JustBash.new(
          files: %{
            "/data.json" => ~s({"title": "My Blog"}),
            "/template.html" => "<title>{{ title }}</title>"
          }
        )

      {result, _} = JustBash.exec(bash, "liquid -d /data.json /template.html")

      assert result.exit_code == 0
      assert result.stdout == "<title>My Blog</title>"
    end

    test "iterates over arrays" do
      bash =
        JustBash.new(files: %{"/data.json" => ~s({"items": ["a", "b", "c"]})})

      {result, _} =
        JustBash.exec(
          bash,
          "liquid -d /data.json -e '{% for x in items %}{{ x }}{% endfor %}'"
        )

      assert result.exit_code == 0
      assert result.stdout == "abc"
    end

    test "iterates over object arrays" do
      bash =
        JustBash.new(
          files: %{
            "/data.json" => ~s({"posts": [{"title": "First"}, {"title": "Second"}]})
          }
        )

      {result, _} =
        JustBash.exec(
          bash,
          "liquid -d /data.json -e '{% for p in posts %}{{ p.title }} {% endfor %}'"
        )

      assert result.exit_code == 0
      assert result.stdout == "First Second "
    end

    test "conditionals" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(
          bash,
          "echo '{\"show\": true}' | liquid -e '{% if show %}visible{% endif %}'"
        )

      assert result.exit_code == 0
      assert result.stdout == "visible"

      {result, _} =
        JustBash.exec(
          bash,
          "echo '{\"show\": false}' | liquid -e '{% if show %}visible{% else %}hidden{% endif %}'"
        )

      assert result.stdout == "hidden"
    end

    test "upcase filter" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "echo '{\"name\": \"alice\"}' | liquid -e '{{ name | upcase }}'")

      assert result.exit_code == 0
      assert result.stdout == "ALICE"
    end

    test "size filter" do
      bash =
        JustBash.new(files: %{"/data.json" => ~s({"items": [1, 2, 3]})})

      {result, _} = JustBash.exec(bash, "liquid -d /data.json -e '{{ items | size }}'")

      assert result.stdout == "3"
    end

    test "works with sqlite json output" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "sqlite3 db 'CREATE TABLE posts (title TEXT, author TEXT)'")

      {_, bash} =
        JustBash.exec(bash, "sqlite3 db \"INSERT INTO posts VALUES ('Hello', 'Alice')\"")

      {_, bash} = JustBash.exec(bash, "sqlite3 db \"INSERT INTO posts VALUES ('World', 'Bob')\"")

      bash =
        put_in(
          bash.fs,
          InMemoryFs.write_file(
            bash.fs,
            "/template.html",
            "{% for post in posts %}<article>{{ post.title }} by {{ post.author }}</article>{% endfor %}"
          )
          |> elem(1)
        )

      {result, _} =
        JustBash.exec(
          bash,
          "sqlite3 db \"SELECT * FROM posts\" --json | jq '{posts: .}' | liquid /template.html"
        )

      assert result.exit_code == 0
      assert result.stdout =~ "Hello by Alice"
      assert result.stdout =~ "World by Bob"
    end

    test "empty data renders with empty variables" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '{}' | liquid -e 'Hello, {{ name }}!'")

      assert result.exit_code == 0
      assert result.stdout == "Hello, !"
    end

    test "error on missing template" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '{}' | liquid /nonexistent.html")

      assert result.exit_code == 1
      assert result.stderr =~ "cannot read template"
    end

    test "error on invalid json" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo 'not json' | liquid -e '{{ x }}'")

      assert result.exit_code == 1
      assert result.stderr =~ "invalid JSON"
    end

    test "error on no template specified" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "echo '{}' | liquid")

      assert result.exit_code == 1
      assert result.stderr =~ "no template specified"
    end

    test "--help shows usage" do
      bash = JustBash.new()

      {result, _} = JustBash.exec(bash, "liquid --help")

      assert result.exit_code == 0
      assert result.stdout =~ "Usage:"
      assert result.stdout =~ "--eval"
    end

    test "nested object access" do
      bash =
        JustBash.new(files: %{"/data.json" => ~s({"user": {"profile": {"name": "Alice"}}})})

      {result, _} =
        JustBash.exec(bash, "liquid -d /data.json -e '{{ user.profile.name }}'")

      assert result.exit_code == 0
      assert result.stdout == "Alice"
    end

    test "assign tag" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(bash, "echo '{}' | liquid -e '{% assign x = \"hello\" %}{{ x }}'")

      assert result.exit_code == 0
      assert result.stdout == "hello"
    end

    test "capture tag" do
      bash = JustBash.new()

      {result, _} =
        JustBash.exec(
          bash,
          "echo '{\"name\": \"World\"}' | liquid -e '{% capture greeting %}Hello, {{ name }}!{% endcapture %}{{ greeting }}'"
        )

      assert result.exit_code == 0
      assert result.stdout == "Hello, World!"
    end
  end
end
