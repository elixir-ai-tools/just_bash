defmodule JustBash.Commands.Cat do
  @moduledoc "The `cat` command - concatenate files and print on stdout."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["cat"]

  @impl true
  def execute(bash, args, stdin) do
    if args == [] and stdin != "" do
      {Command.ok(stdin), bash}
    else
      args = if args == [], do: ["-"], else: args

      {stdout, stderr, exit_code, _stdin_consumed, fs} =
        Enum.reduce(args, {"", "", 0, false, bash.fs}, fn path, acc ->
          read_and_accumulate(bash, path, stdin, acc)
        end)

      {Command.result(stdout, stderr, exit_code), %{bash | fs: fs}}
    end
  end

  defp read_and_accumulate(_bash, "-", stdin, {out_acc, err_acc, code_acc, stdin_consumed, fs}) do
    if stdin_consumed do
      {out_acc, err_acc, code_acc, true, fs}
    else
      {out_acc <> stdin, err_acc, code_acc, true, fs}
    end
  end

  defp read_and_accumulate(bash, path, _stdin, {out_acc, err_acc, code_acc, stdin_consumed, fs}) do
    resolved = FS.resolve_path(bash.cwd, path)

    case FS.read_file(fs, resolved) do
      {:ok, content, fs} ->
        {out_acc <> content, err_acc, code_acc, stdin_consumed, fs}

      {:error, err} ->
        {out_acc, err_acc <> "cat: #{path}: #{FS.strerror(err)}\n", 1, stdin_consumed, fs}
    end
  end
end
