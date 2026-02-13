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
      {stdout, stderr, exit_code} =
        Enum.reduce(args, {"", "", 0}, fn path, acc ->
          read_and_accumulate(bash, path, acc)
        end)

      {Command.result(stdout, stderr, exit_code), bash}
    end
  end

  defp read_and_accumulate(bash, path, {out_acc, err_acc, code_acc}) do
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} ->
        {out_acc <> content, err_acc, code_acc}

      {:error, :enoent} ->
        {out_acc, err_acc <> "cat: #{path}: No such file or directory\n", 1}

      {:error, :eisdir} ->
        {out_acc, err_acc <> "cat: #{path}: Is a directory\n", 1}

      {:error, _} ->
        {out_acc, err_acc <> "cat: #{path}: cannot read\n", 1}
    end
  end
end
