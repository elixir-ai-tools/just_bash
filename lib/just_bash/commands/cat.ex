defmodule JustBash.Commands.Cat do
  @moduledoc "The `cat` command - concatenate files and print on stdout."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["cat"]

  @impl true
  def execute(bash, args, stdin) do
    if args == [] and stdin != "" do
      {Command.ok(stdin), bash}
    else
      args = if args == [], do: ["-"], else: args

      {stdout, stderr, exit_code, _stdin_consumed} =
        Enum.reduce(args, {"", "", 0, false}, fn path, acc ->
          read_and_accumulate(bash, path, stdin, acc)
        end)

      {Command.result(stdout, stderr, exit_code), bash}
    end
  end

  defp read_and_accumulate(_bash, "-", stdin, {out_acc, err_acc, code_acc, stdin_consumed}) do
    if stdin_consumed do
      {out_acc, err_acc, code_acc, true}
    else
      {out_acc <> stdin, err_acc, code_acc, true}
    end
  end

  defp read_and_accumulate(bash, path, _stdin, {out_acc, err_acc, code_acc, stdin_consumed}) do
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} ->
        {out_acc <> content, err_acc, code_acc, stdin_consumed}

      {:error, :enoent} ->
        {out_acc, err_acc <> "cat: #{path}: No such file or directory\n", 1, stdin_consumed}

      {:error, :eisdir} ->
        {out_acc, err_acc <> "cat: #{path}: Is a directory\n", 1, stdin_consumed}
    end
  end
end
