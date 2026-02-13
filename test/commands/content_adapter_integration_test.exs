defmodule JustBash.Commands.ContentAdapterIntegrationTest do
  use ExUnit.Case, async: true

  alias JustBash.Fs.Content.FunctionContent

  describe "cat with function-backed files" do
    test "reads function-backed file" do
      bash =
        JustBash.new(files: %{
          "/dynamic.txt" => fn -> "generated content" end
        })

      {result, _bash} = JustBash.exec(bash, "cat /dynamic.txt")

      assert result.stdout == "generated content"
      assert result.exit_code == 0
    end

    test "reads multiple function-backed files" do
      bash =
        JustBash.new(files: %{
          "/file1.txt" => fn -> "first" end,
          "/file2.txt" => fn -> "second" end
        })

      {result, _bash} = JustBash.exec(bash, "cat /file1.txt /file2.txt")

      assert result.stdout == "firstsecond"
      assert result.exit_code == 0
    end

    test "handles function errors gracefully" do
      bash =
        JustBash.new(files: %{
          "/error.txt" => FunctionContent.new(fn -> raise "boom" end)
        })

      {result, _bash} = JustBash.exec(bash, "cat /error.txt")

      assert result.stderr =~ "cannot read"
      assert result.exit_code == 1
    end
  end

  describe "head with function-backed files" do
    test "reads first lines from function-backed file" do
      bash =
        JustBash.new(files: %{
          "/lines.txt" => fn -> "line1\nline2\nline3\nline4\nline5\n" end
        })

      {result, _bash} = JustBash.exec(bash, "head -n 3 /lines.txt")

      assert result.stdout == "line1\nline2\nline3\n"
      assert result.exit_code == 0
    end
  end

  describe "tail with function-backed files" do
    test "reads last lines from function-backed file" do
      bash =
        JustBash.new(files: %{
          "/lines.txt" => fn -> "line1\nline2\nline3\nline4\nline5\n" end
        })

      {result, _bash} = JustBash.exec(bash, "tail -n 2 /lines.txt")

      assert result.stdout == "line4\nline5\n"
      assert result.exit_code == 0
    end
  end

  describe "grep with function-backed files" do
    test "searches function-backed file" do
      bash =
        JustBash.new(files: %{
          "/data.txt" => fn -> "apple\nbanana\ncherry\n" end
        })

      {result, _bash} = JustBash.exec(bash, "grep banana /data.txt")

      assert result.stdout == "banana\n"
      assert result.exit_code == 0
    end
  end

  describe "wc with function-backed files" do
    test "counts bytes in function-backed file" do
      bash =
        JustBash.new(files: %{
          "/data.txt" => fn -> "hello world" end
        })

      {result, _bash} = JustBash.exec(bash, "wc -c /data.txt")

      assert result.stdout =~ "11"
      assert result.exit_code == 0
    end
  end

  describe "source with function-backed files" do
    test "executes script from function-backed file" do
      bash =
        JustBash.new(files: %{
          "/script.sh" => fn -> "echo hello from script" end
        })

      {result, _bash} = JustBash.exec(bash, "source /script.sh")

      assert result.stdout == "hello from script\n"
      assert result.exit_code == 0
    end

    test "script can modify environment" do
      bash =
        JustBash.new(files: %{
          "/setvar.sh" => fn -> "export MY_VAR=value123" end
        })

      {result, bash} = JustBash.exec(bash, "source /setvar.sh")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "echo $MY_VAR")
      assert result.stdout == "value123\n"
    end
  end

  describe "redirections with function-backed files" do
    test "redirect overwrites function-backed file with binary" do
      bash =
        JustBash.new(files: %{
          "/dynamic.txt" => fn -> "original" end
        })

      # First read should show original
      {result, bash} = JustBash.exec(bash, "cat /dynamic.txt")
      assert result.stdout == "original"

      # Redirect to overwrite
      {result, bash} = JustBash.exec(bash, "echo new > /dynamic.txt")
      assert result.exit_code == 0

      # Now it should be binary content
      {result, _bash} = JustBash.exec(bash, "cat /dynamic.txt")
      assert result.stdout == "new\n"
    end

    test "append to function-backed file resolves then appends" do
      bash =
        JustBash.new(files: %{
          "/dynamic.txt" => fn -> "start" end
        })

      {result, bash} = JustBash.exec(bash, "echo end >> /dynamic.txt")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "cat /dynamic.txt")
      assert result.stdout == "startend\n"
    end
  end

  describe "pipes with function-backed files" do
    test "pipes function-backed file through multiple commands" do
      bash =
        JustBash.new(files: %{
          "/data.txt" => fn -> "apple\nbanana\ncherry\napricot\n" end
        })

      {result, _bash} = JustBash.exec(bash, "cat /data.txt | grep a | wc -l")

      assert result.stdout =~ "3"
      assert result.exit_code == 0
    end
  end

  describe "cp command with function-backed files" do
    test "cp resolves function-backed source to binary destination" do
      bash =
        JustBash.new(files: %{
          "/source.txt" => fn -> "dynamic" end
        })

      {result, bash} = JustBash.exec(bash, "cp /source.txt /dest.txt")
      assert result.exit_code == 0

      # Destination should have binary content (from resolved function)
      {result, _bash} = JustBash.exec(bash, "cat /dest.txt")
      assert result.stdout == "dynamic"
    end
  end

  describe "materialize_files" do
    test "resolves all function-backed files to binary" do
      call_count = :counters.new(1, [])

      bash =
        JustBash.new(files: %{
          "/counter.txt" =>
            fn ->
              :counters.add(call_count, 1, 1)
              "call #{:counters.get(call_count, 1)}"
            end
        })

      # Materialize once
      {:ok, bash} = JustBash.materialize_files(bash)

      # Multiple reads should return the same content (function called only once)
      {result1, bash} = JustBash.exec(bash, "cat /counter.txt")
      {result2, bash} = JustBash.exec(bash, "cat /counter.txt")
      {result3, _bash} = JustBash.exec(bash, "cat /counter.txt")

      assert result1.stdout == "call 1"
      assert result2.stdout == "call 1"
      assert result3.stdout == "call 1"
    end

    test "handles materialization errors" do
      bash =
        JustBash.new(files: %{
          "/error.txt" => FunctionContent.new(fn -> raise "boom" end)
        })

      assert {:error, {:function_error, _}} = JustBash.materialize_files(bash)
    end
  end

  describe "MFA tuple functions" do
    test "reads file backed by MFA tuple" do
      bash =
        JustBash.new(files: %{
          "/upper.txt" => FunctionContent.new({String, :upcase, ["hello world"]})
        })

      {result, _bash} = JustBash.exec(bash, "cat /upper.txt")

      assert result.stdout == "HELLO WORLD"
      assert result.exit_code == 0
    end
  end
end
