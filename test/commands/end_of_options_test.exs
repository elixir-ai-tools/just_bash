defmodule JustBash.Commands.EndOfOptionsTest do
  @moduledoc """
  `--` ends option parsing. Everything after it is an operand.

  Some commands honoured that, others treated `--` as a filename or as an
  invalid option. The worst case printed the correct result *and* exited 1
  (`shasum -- /f`). Issue #83 wants the same treatment as #68's unknown-flag
  matrix: every Registry command that takes a file operand is enumerated, so a
  new command cannot join without classifying.
  """
  use ExUnit.Case, async: true

  alias JustBash.Commands.Registry
  alias JustBash.Commands.StdinOperand

  @content "hello\n"
  @other "world\n"
  @json "{\"k\":1}\n"
  @markdown "# Hi\n"
  @script "echo sourced\n"

  # Every command whose invocation takes a file operand. FILE is replaced with
  # the path; `--` is inserted immediately before that operand. The reference
  # run is the same invocation without `--`. They must agree, succeed, and not
  # mention `--` as a file or an option.
  #
  # A row may name its own path (a directory, a JSON document, a destination
  # that should not already exist) and the stdin a writer such as `tee` needs.
  @file_operand [
    "cat FILE",
    "head FILE",
    "tail FILE",
    "tac FILE",
    "rev FILE",
    "nl FILE",
    "fold FILE",
    "expand FILE",
    "paste FILE",
    "base64 FILE",
    "md5sum FILE",
    "sha256sum FILE",
    "shasum FILE",
    "od -c FILE",
    "xxd FILE",
    "cut -c1 FILE",
    "file FILE",
    "stat FILE",
    "sort FILE",
    "uniq FILE",
    "realpath FILE",
    "touch FILE",
    {"wc -l FILE", "/f", ""},
    {"grep hello FILE", "/f", ""},
    {"sed -n p FILE", "/f", ""},
    {"awk '{print}' FILE", "/f", ""},
    {"jq . FILE", "/j.json", ""},
    {"markdown FILE", "/readme.md", ""},
    {"md FILE", "/readme.md", ""},
    {"source FILE", "/script.sh", ""},
    {". FILE", "/script.sh", ""},
    {"comm FILE FILE", "/f", ""},
    {"diff FILE FILE", "/f", ""},
    {"cp FILE /out", "/f", ""},
    {"mv FILE /out", "/f", ""},
    {"rm FILE", "/f", ""},
    {"ls FILE", "/d", ""},
    {"find FILE", "/d", ""},
    {"tree FILE", "/d", ""},
    {"du FILE", "/d", ""},
    {"cd FILE; pwd", "/d", ""},
    {"mkdir FILE", "/newdir", ""},
    {"tee FILE", "/out", @content},
    {"ln FILE /link", "/f", ""},
    {"chmod 644 FILE", "/f", ""},
    {"chown u FILE", "/f", ""},
    {"readlink -f FILE", "/f", ""}
  ]

  # The rest of the registry: `--` is not a file-operand marker for these.
  # Kept explicit so a command added to the registry has to be classified.
  @no_file_operand %{
    "echo" => "writes arguments; does not open a path",
    "true" => "ignores operands",
    ":" => "alias of true",
    "false" => "ignores operands",
    "pwd" => "prints the working directory",
    "export" => "assigns shell variables",
    "unset" => "unsets shell variables",
    "test" => "expression operands, not a file-opening utility",
    "[" => "alias of test",
    "printf" => "formats arguments",
    "basename" => "string operation on a path name, does not open it",
    "dirname" => "string operation on a path name, does not open it",
    "read" => "reads stdin into variables",
    "seq" => "emits numbers",
    "tr" => "translates stdin character sets",
    "date" => "prints a date; operands are format strings",
    "sleep" => "duration operand",
    "exit" => "status operand",
    "env" => "assigns environment and runs a command",
    "printenv" => "prints environment variables",
    "which" => "looks up command names",
    "hostname" => "prints the host name",
    "xargs" => "builds a command from stdin",
    "curl" => "URL operand",
    "wget" => "URL operand",
    "set" => "shell options and positional parameters",
    "local" => "assigns function-local variables",
    "declare" => "alias of local",
    "typeset" => "alias of local",
    "break" => "loop control",
    "continue" => "loop control",
    "shift" => "positional parameters",
    "return" => "function return",
    "getopts" => "option parsing builtin",
    "trap" => "signal handlers",
    "eval" => "evaluates a string as a script",
    "command" => "looks up / invokes another command",
    "uname" => "prints system information",
    "mktemp" => "template operand, not an existing file",
    "whoami" => "prints the user name",
    "id" => "prints user identity",
    "nproc" => "prints CPU count",
    "arch" => "prints architecture",
    "yes" => "repeats arguments",
    "type" => "describes command names"
  }

  @rows Enum.map(@file_operand, fn
          {script, path, stdin} -> {script, path, stdin}
          script -> {script, "/f", ""}
        end)

  describe "StdinOperand.split_end_of_options/1" do
    test "splits at the first -- and leaves a second -- as an operand" do
      assert StdinOperand.split_end_of_options(["-n", "--", "/f"]) == {["-n"], ["/f"]}
      assert StdinOperand.split_end_of_options(["--", "-n", "/f"]) == {[], ["-n", "/f"]}
      assert StdinOperand.split_end_of_options(["--", "--", "/f"]) == {[], ["--", "/f"]}
      assert StdinOperand.split_end_of_options(["/f", "-n"]) == {["/f", "-n"], []}
    end

    test "drop_end_of_options/1 concatenates both sides so -- is not a filename" do
      assert StdinOperand.drop_end_of_options(["--", "/f"]) == ["/f"]
      assert StdinOperand.drop_end_of_options(["/f", "--"]) == ["/f"]
      assert StdinOperand.drop_end_of_options(["--", "--"]) == ["--"]
    end
  end

  describe "the registry is fully classified" do
    test "every command either takes a file operand or is skipped with a reason" do
      named = Enum.map(@rows, fn {script, _, _} -> command_name(script) end)
      classified = MapSet.new(named ++ Map.keys(@no_file_operand))

      assert MapSet.new(Registry.list()) == classified
    end
  end

  describe "`--` ends option parsing for every file-operand command" do
    for {script, path, stdin} <- @rows do
      test "#{script}" do
        {script, path, stdin} = {unquote(script), unquote(path), unquote(stdin)}
        with_dd = insert_end_of_options(script)
        {reference, _} = run(script, path, stdin)
        {observed, after_bash} = run(with_dd, path, stdin)

        assert reference.exit_code == 0,
               "#{script} without -- exited #{reference.exit_code}: #{inspect(reference)}"

        assert observed.exit_code == 0,
               "#{with_dd} exited #{observed.exit_code}: #{inspect(observed)}"

        assert strip_volatile(observed.stdout) == strip_volatile(reference.stdout)
        assert observed.stderr == reference.stderr

        refute observed.stderr =~ "--",
               "#{with_dd} mentioned -- in stderr: #{inspect(observed.stderr)}"

        # touch/mkdir used to create a file named `--` and still exit 0, so
        # comparing transcripts was not enough.
        {leftover, _} = JustBash.exec(after_bash, ~s[test -e "./--" && echo leaked || echo clean])
        assert leftover.stdout =~ "clean"
      end
    end
  end

  describe "the issue #83 table" do
    test "shasum -- /f hashes the file and exits 0, with nothing about --" do
      {result, _} = JustBash.exec(sandbox(), "shasum -- /f")
      {expected, _} = JustBash.exec(sandbox(), "shasum /f")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout == expected.stdout
      assert result.stdout =~ ~r/^[0-9a-f]{40}  \/f\n$/
    end

    test "sha256sum -- /f hashes the file and exits 0" do
      {result, _} = JustBash.exec(sandbox(), "sha256sum -- /f")
      {expected, _} = JustBash.exec(sandbox(), "sha256sum /f")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout == expected.stdout
    end

    test "cat -- /f prints the file and exits 0" do
      {result, _} = JustBash.exec(sandbox(), "cat -- /f")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout == @content
    end

    test "md5sum -- /f hashes the file and exits 0" do
      {result, _} = JustBash.exec(sandbox(), "md5sum -- /f")
      {expected, _} = JustBash.exec(sandbox(), "md5sum /f")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout == expected.stdout
    end

    test "base64 -- /f encodes the file and exits 0" do
      {result, _} = JustBash.exec(sandbox(), "base64 -- /f")
      {expected, _} = JustBash.exec(sandbox(), "base64 /f")

      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout == expected.stdout
    end
  end

  describe "a filename that begins with a dash" do
    # POSIX `--` exists so a file named `-f` is not taken as a flag.
    test "cat -- -f reads a file named -f" do
      bash = JustBash.new(files: %{"/-f" => "dashfile\n"})

      assert {%{stdout: "dashfile\n", stderr: "", exit_code: 0}, _} =
               JustBash.exec(bash, "cd /; cat -- -f")
    end
  end

  defp sandbox do
    JustBash.new(
      files: %{
        "/f" => @content,
        "/g" => @other,
        "/j.json" => @json,
        "/readme.md" => @markdown,
        "/script.sh" => @script,
        "/d/x" => "x\n"
      }
    )
  end

  defp insert_end_of_options(script) do
    String.replace(script, "FILE", "-- FILE", global: false)
  end

  defp run(script, path, stdin) do
    invoked = String.replace(script, "FILE", path)
    bash = sandbox()

    if stdin == "" do
      JustBash.exec(bash, invoked)
    else
      JustBash.exec(bash, "printf #{inspect(stdin)} | " <> invoked)
    end
  end

  defp strip_volatile(stdout) do
    String.replace(stdout, ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z/, "<ts>")
  end

  # Take the token that names a Registry command. `source` / `.` are the first
  # token; `cd FILE; pwd` still starts with `cd`.
  defp command_name(script) do
    script
    |> String.split(" ", trim: true)
    |> Enum.find(&Registry.exists?/1)
  end
end
