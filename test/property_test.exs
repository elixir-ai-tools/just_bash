defmodule JustBash.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduledoc """
  Property-based tests for JustBash using StreamData.
  These tests verify properties that should hold for all inputs.
  """

  describe "echo command properties" do
    property "echo outputs its input followed by newline" do
      check all(text <- string(:alphanumeric, min_length: 1, max_length: 100)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo #{text}")
        assert result.stdout == "#{text}\n"
        assert result.exit_code == 0
      end
    end

    property "echo -n outputs its input without newline" do
      check all(text <- string(:alphanumeric, min_length: 1, max_length: 100)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo -n #{text}")
        assert result.stdout == text
        assert result.exit_code == 0
      end
    end

    property "empty echo always produces just a newline" do
      check all(_ <- constant(:ok)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo")
        assert result.stdout == "\n"
      end
    end
  end

  describe "cat command properties" do
    property "cat preserves file content exactly" do
      check all(content <- string(:printable, max_length: 500)) do
        bash = JustBash.new(files: %{"/test.txt" => content})
        {result, _} = JustBash.exec(bash, "cat /test.txt")
        assert result.stdout == content
        assert result.exit_code == 0
      end
    end

    property "cat of multiple files concatenates them" do
      check all(
              content1 <- string(:alphanumeric, max_length: 100),
              content2 <- string(:alphanumeric, max_length: 100)
            ) do
        bash = JustBash.new(files: %{"/a.txt" => content1, "/b.txt" => content2})
        {result, _} = JustBash.exec(bash, "cat /a.txt /b.txt")
        assert result.stdout == content1 <> content2
      end
    end
  end

  describe "head/tail properties" do
    property "head -n returns at most n lines" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 20
                ),
              n <- integer(1..10)
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "head -n #{n} /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        assert length(result_lines) <= n
      end
    end

    property "tail -n returns at most n lines" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 20
                ),
              n <- integer(1..10)
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "tail -n #{n} /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        assert length(result_lines) <= n
      end
    end
  end

  describe "sort properties" do
    # Locale-aware comparison matching bash's en_US.UTF-8 collation
    defp locale_compare(a, b) do
      a_down = String.downcase(a)
      b_down = String.downcase(b)

      cond do
        a_down < b_down -> true
        a_down > b_down -> false
        true -> lowercase_first?(a, b)
      end
    end

    defp lowercase_first?(a, b) do
      compare_lowercase_first(String.graphemes(a), String.graphemes(b))
    end

    defp compare_lowercase_first([], []), do: true
    defp compare_lowercase_first([], _), do: true
    defp compare_lowercase_first(_, []), do: false

    defp compare_lowercase_first([a_char | a_rest], [b_char | b_rest]) do
      a_down = String.downcase(a_char)
      b_down = String.downcase(b_char)

      cond do
        a_down != b_down -> a_down <= b_down
        a_char == b_char -> compare_lowercase_first(a_rest, b_rest)
        String.downcase(a_char) == a_char and String.upcase(a_char) != a_char -> true
        String.downcase(b_char) == b_char and String.upcase(b_char) != b_char -> false
        true -> compare_lowercase_first(a_rest, b_rest)
      end
    end

    property "sort output is sorted" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 20
                )
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "sort /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        assert result_lines == Enum.sort(result_lines, &locale_compare/2)
      end
    end

    property "sort -r output is reverse sorted" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 20
                )
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "sort -r /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        assert result_lines == Enum.sort(result_lines, &(not locale_compare(&1, &2)))
      end
    end

    property "sort -u removes duplicates" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 20
                )
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "sort -u /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        assert result_lines == Enum.uniq(result_lines)
      end
    end

    property "sort -n sorts numerically" do
      check all(nums <- list_of(integer(-1000..1000), min_length: 1, max_length: 20)) do
        content = Enum.map_join(nums, "\n", &to_string/1) <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "sort -n /file.txt")

        result_nums =
          result.stdout
          |> String.split("\n", trim: true)
          |> Enum.map(&String.to_integer/1)

        assert result_nums == Enum.sort(nums)
      end
    end
  end

  describe "wc properties" do
    property "wc -l counts lines correctly" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 0,
                  max_length: 20
                )
            ) do
        content = Enum.join(lines, "\n") <> if lines != [], do: "\n", else: ""
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "wc -l /file.txt")

        reported_count =
          result.stdout
          |> String.split()
          |> hd()
          |> String.to_integer()

        assert reported_count == length(lines)
      end
    end

    property "wc -c counts bytes correctly" do
      check all(content <- string(:alphanumeric, max_length: 200)) do
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "wc -c /file.txt")

        reported_count =
          result.stdout
          |> String.split()
          |> hd()
          |> String.to_integer()

        assert reported_count == byte_size(content)
      end
    end
  end

  describe "uniq properties" do
    property "uniq removes consecutive duplicates" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 20
                )
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "uniq /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        expected = Enum.dedup(lines)
        assert result_lines == expected
      end
    end
  end

  describe "rev properties" do
    property "rev reverses each line" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 50),
                  min_length: 1,
                  max_length: 10
                )
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "rev /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        expected = Enum.map(lines, &String.reverse/1)
        assert result_lines == expected
      end
    end
  end

  describe "tac properties" do
    property "tac reverses line order" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                  min_length: 1,
                  max_length: 20
                )
            ) do
        content = Enum.join(lines, "\n") <> "\n"
        bash = JustBash.new(files: %{"/file.txt" => content})
        {result, _} = JustBash.exec(bash, "tac /file.txt")

        result_lines = String.split(result.stdout, "\n", trim: true)
        assert result_lines == Enum.reverse(lines)
      end
    end
  end

  describe "arithmetic properties" do
    property "addition is commutative" do
      check all(
              a <- integer(-1000..1000),
              b <- integer(-1000..1000)
            ) do
        bash = JustBash.new()
        {r1, _} = JustBash.exec(bash, "echo $((#{a} + #{b}))")
        {r2, _} = JustBash.exec(bash, "echo $((#{b} + #{a}))")
        assert String.trim(r1.stdout) == String.trim(r2.stdout)
      end
    end

    property "multiplication is commutative" do
      check all(
              a <- integer(-100..100),
              b <- integer(-100..100)
            ) do
        bash = JustBash.new()
        {r1, _} = JustBash.exec(bash, "echo $((#{a} * #{b}))")
        {r2, _} = JustBash.exec(bash, "echo $((#{b} * #{a}))")
        assert String.trim(r1.stdout) == String.trim(r2.stdout)
      end
    end

    property "subtraction produces correct result" do
      check all(
              a <- integer(-1000..1000),
              b <- integer(-1000..1000)
            ) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo $((#{a} - #{b}))")
        expected = a - b
        assert String.trim(result.stdout) == to_string(expected)
      end
    end

    property "integer division produces correct result" do
      check all(
              a <- integer(-1000..1000),
              b <- integer(1..100)
            ) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo $((#{a} / #{b}))")
        expected = div(a, b)
        assert String.trim(result.stdout) == to_string(expected)
      end
    end

    property "modulo produces correct result" do
      check all(
              a <- integer(0..1000),
              b <- integer(1..100)
            ) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo $((#{a} % #{b}))")
        expected = rem(a, b)
        assert String.trim(result.stdout) == to_string(expected)
      end
    end
  end

  describe "variable properties" do
    property "variable assignment and retrieval" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 10),
              value <- string(:alphanumeric, min_length: 1, max_length: 50)
            ) do
        var_name = "VAR_" <> name
        bash = JustBash.new()
        {_, bash} = JustBash.exec(bash, "#{var_name}=#{value}")
        {result, _} = JustBash.exec(bash, "echo $#{var_name}")
        assert result.stdout == "#{value}\n"
      end
    end

    property "export and retrieval" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 10),
              value <- string(:alphanumeric, min_length: 1, max_length: 50)
            ) do
        var_name = "EXP_" <> name
        bash = JustBash.new()
        {_, bash} = JustBash.exec(bash, "export #{var_name}=#{value}")
        assert bash.env[var_name] == value
      end
    end
  end

  describe "seq properties" do
    property "seq produces correct count" do
      check all(n <- integer(1..50)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "seq #{n}")
        lines = String.split(result.stdout, "\n", trim: true)
        assert length(lines) == n
      end
    end

    property "seq from a to b produces correct range" do
      check all(
              a <- integer(1..20),
              diff <- integer(0..20)
            ) do
        b = a + diff
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "seq #{a} #{b}")
        lines = String.split(result.stdout, "\n", trim: true)
        expected = Enum.map(a..b, &to_string/1)
        assert lines == expected
      end
    end
  end

  describe "file operations properties" do
    property "touch creates file that exists" do
      check all(name <- string(:alphanumeric, min_length: 1, max_length: 20)) do
        filename = "/#{name}.txt"
        bash = JustBash.new()
        {_, bash} = JustBash.exec(bash, "touch #{filename}")
        {result, _} = JustBash.exec(bash, "[ -f #{filename} ] && echo yes || echo no")
        assert result.stdout == "yes\n"
      end
    end

    property "mkdir creates directory that exists" do
      check all(name <- string(:alphanumeric, min_length: 1, max_length: 20)) do
        dirname = "/#{name}"
        bash = JustBash.new()
        {_, bash} = JustBash.exec(bash, "mkdir #{dirname}")
        {result, _} = JustBash.exec(bash, "[ -d #{dirname} ] && echo yes || echo no")
        assert result.stdout == "yes\n"
      end
    end

    property "cp preserves content" do
      check all(content <- string(:alphanumeric, max_length: 100)) do
        bash = JustBash.new(files: %{"/src.txt" => content})
        {_, bash} = JustBash.exec(bash, "cp /src.txt /dst.txt")
        {result, _} = JustBash.exec(bash, "cat /dst.txt")
        assert result.stdout == content
      end
    end

    property "mv moves file completely" do
      check all(content <- string(:alphanumeric, max_length: 100)) do
        bash = JustBash.new(files: %{"/src.txt" => content})
        {_, bash} = JustBash.exec(bash, "mv /src.txt /dst.txt")

        {result_dst, _} = JustBash.exec(bash, "cat /dst.txt")
        assert result_dst.stdout == content

        {result_src, _} = JustBash.exec(bash, "cat /src.txt")
        assert result_src.exit_code == 1
      end
    end
  end

  describe "exit code properties" do
    property "true always returns 0" do
      check all(_ <- constant(:ok)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "true")
        assert result.exit_code == 0
      end
    end

    property "false always returns 1" do
      check all(_ <- constant(:ok)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "false")
        assert result.exit_code == 1
      end
    end

    property "exit returns specified code" do
      check all(code <- integer(0..255)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "exit #{code}")
        assert result.exit_code == code
      end
    end
  end

  describe "test command properties" do
    property "test -z returns 0 for empty string" do
      check all(_ <- constant(:ok)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "test -z ''")
        assert result.exit_code == 0
      end
    end

    property "test -n returns 0 for non-empty string" do
      check all(s <- string(:alphanumeric, min_length: 1, max_length: 50)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "test -n '#{s}'")
        assert result.exit_code == 0
      end
    end

    property "numeric equality is reflexive" do
      check all(n <- integer(-1000..1000)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "[ #{n} -eq #{n} ]")
        assert result.exit_code == 0
      end
    end

    property "numeric less than is consistent" do
      check all(
              a <- integer(-1000..1000),
              diff <- integer(1..100)
            ) do
        b = a + diff
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "[ #{a} -lt #{b} ]")
        assert result.exit_code == 0
      end
    end
  end

  describe "brace expansion properties" do
    property "range expansion produces correct count" do
      check all(
              a <- integer(1..20),
              diff <- integer(0..20)
            ) do
        b = a + diff
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {#{a}..#{b}}")
        words = String.split(String.trim(result.stdout))
        assert length(words) == diff + 1
      end
    end

    property "range expansion produces correct values" do
      check all(
              a <- integer(1..20),
              diff <- integer(0..10)
            ) do
        b = a + diff
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {#{a}..#{b}}")
        words = String.split(String.trim(result.stdout))
        expected = Enum.map(a..b, &to_string/1)
        assert words == expected
      end
    end

    property "reverse range expansion produces reversed values" do
      check all(
              a <- integer(1..20),
              diff <- integer(1..10)
            ) do
        b = a + diff
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {#{b}..#{a}}")
        words = String.split(String.trim(result.stdout))
        expected = Enum.map(b..a//-1, &to_string/1)
        assert words == expected
      end
    end

    property "list expansion produces correct count" do
      check all(
              items <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                  min_length: 2,
                  max_length: 5
                )
            ) do
        list = Enum.join(items, ",")
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {#{list}}")
        words = String.split(String.trim(result.stdout))
        assert length(words) == length(items)
      end
    end

    property "list expansion preserves items" do
      check all(
              items <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                  min_length: 2,
                  max_length: 5
                )
            ) do
        list = Enum.join(items, ",")
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {#{list}}")
        words = String.split(String.trim(result.stdout))
        assert words == items
      end
    end

    # Reserved words that would confuse the parser
    @reserved_words ~w(if then else elif fi do done case esac while until for in function)

    property "prefix with list expansion produces correct count" do
      check all(
              prefix <-
                string(:alphanumeric, min_length: 1, max_length: 5)
                |> filter(&(&1 not in @reserved_words)),
              items <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 3),
                  min_length: 2,
                  max_length: 4
                )
            ) do
        list = Enum.join(items, ",")
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo #{prefix}{#{list}}")
        words = String.split(String.trim(result.stdout))
        assert length(words) == length(items)
        assert Enum.all?(words, &String.starts_with?(&1, prefix))
      end
    end

    property "suffix with list expansion produces correct count" do
      check all(
              suffix <-
                string(:alphanumeric, min_length: 1, max_length: 5)
                |> filter(&(&1 not in @reserved_words)),
              items <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 3),
                  min_length: 2,
                  max_length: 4
                )
            ) do
        list = Enum.join(items, ",")
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {#{list}}#{suffix}")
        words = String.split(String.trim(result.stdout))
        assert length(words) == length(items)
        assert Enum.all?(words, &String.ends_with?(&1, suffix))
      end
    end

    property "single item brace is literal" do
      check all(item <- string(:alphanumeric, min_length: 1, max_length: 10)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {#{item}}")
        assert String.trim(result.stdout) == "{#{item}}"
      end
    end

    property "empty braces is literal" do
      check all(_ <- constant(:ok)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo {}")
        assert String.trim(result.stdout) == "{}"
      end
    end
  end

  describe "nested arithmetic properties" do
    property "nested parentheses compute correctly" do
      check all(
              a <- integer(1..50),
              b <- integer(1..50),
              c <- integer(1..50)
            ) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo $((#{a} + (#{b} + #{c})))")
        expected = a + b + c
        assert String.trim(result.stdout) == to_string(expected)
      end
    end

    property "double nested parentheses compute correctly" do
      check all(
              a <- integer(1..20),
              b <- integer(1..20),
              c <- integer(1..20),
              d <- integer(1..20)
            ) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo $((#{a} + (#{b} + (#{c} + #{d}))))")
        expected = a + b + c + d
        assert String.trim(result.stdout) == to_string(expected)
      end
    end

    property "nested multiplication has correct precedence" do
      check all(
              a <- integer(1..10),
              b <- integer(1..10),
              c <- integer(1..10)
            ) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo $((#{a} * (#{b} + #{c})))")
        expected = a * (b + c)
        assert String.trim(result.stdout) == to_string(expected)
      end
    end
  end

  describe "parameter expansion properties" do
    property "default value used when unset" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 5),
              default <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        var_name = "UNSET_" <> name
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo ${#{var_name}:-#{default}}")
        assert String.trim(result.stdout) == default
      end
    end

    property "default value not used when set" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 5),
              value <- string(:alphanumeric, min_length: 1, max_length: 10),
              default <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        var_name = "SET_" <> name
        bash = JustBash.new()
        {_, bash} = JustBash.exec(bash, "#{var_name}=#{value}")
        {result, _} = JustBash.exec(bash, "echo ${#{var_name}:-#{default}}")
        assert String.trim(result.stdout) == value
      end
    end

    property "alternate value used when set" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 5),
              value <- string(:alphanumeric, min_length: 1, max_length: 10),
              alt <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        var_name = "ALT_" <> name
        bash = JustBash.new()
        {_, bash} = JustBash.exec(bash, "#{var_name}=#{value}")
        {result, _} = JustBash.exec(bash, "echo ${#{var_name}:+#{alt}}")
        assert String.trim(result.stdout) == alt
      end
    end

    property "alternate value not used when unset" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 5),
              alt <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        var_name = "UNSETALT_" <> name
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo ${#{var_name}:+#{alt}}")
        assert String.trim(result.stdout) == ""
      end
    end

    property "string length is correct" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 5),
              value <- string(:alphanumeric, min_length: 0, max_length: 50)
            ) do
        var_name = "LEN_" <> name
        bash = JustBash.new()
        {_, bash} = JustBash.exec(bash, "#{var_name}=#{value}")
        {result, _} = JustBash.exec(bash, "echo ${##{var_name}}")
        assert String.trim(result.stdout) == to_string(String.length(value))
      end
    end
  end

  describe "quoting properties" do
    property "single quotes preserve literal content" do
      check all(text <- string(:alphanumeric, min_length: 1, max_length: 50)) do
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo '#{text}'")
        assert String.trim(result.stdout) == text
      end
    end

    property "double quotes preserve spaces" do
      check all(
              word1 <- string(:alphanumeric, min_length: 1, max_length: 10),
              word2 <- string(:alphanumeric, min_length: 1, max_length: 10)
            ) do
        text = "#{word1}   #{word2}"
        bash = JustBash.new()
        {result, _} = JustBash.exec(bash, "echo \"#{text}\"")
        assert String.trim(result.stdout) == text
      end
    end

    property "escaped dollar in double quotes is literal" do
      check all(text <- string(:alphanumeric, min_length: 1, max_length: 10)) do
        bash = JustBash.new()
        # Note: The \\ becomes \ in Elixir string, and that \ escapes $ in bash
        {result, _} = JustBash.exec(bash, "echo \"\\$#{text}\"")
        assert String.trim(result.stdout) == "$#{text}"
      end
    end
  end
end
