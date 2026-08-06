defmodule JustBash.Commands.Tac do
  @moduledoc "The `tac` command - concatenate and print files in reverse."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.FS

  @impl true
  def names, do: ["tac"]

  @impl true
  def execute(bash, args, stdin) do
    files = Enum.reject(args, &String.starts_with?(&1, "-"))

    content =
      if files == [] or files == ["-"] do
        {:ok, stdin, bash.fs}
      else
        read_files(bash, files)
      end

    case content do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, data, fs} ->
        output = reverse_lines(data)
        {Command.ok(output), %{bash | fs: fs}}
    end
  end

  defp read_files(bash, files) do
    Enum.reduce_while(files, {:ok, "", bash.fs}, fn file, {:ok, acc, fs} ->
      resolved = FS.resolve_path(bash.cwd, file)

      case FS.read_file(fs, resolved) do
        {:ok, data, fs} -> {:cont, {:ok, acc <> data, fs}}
        {:error, error} -> {:halt, {:error, read_error(file, error)}}
      end
    end)
  end

  # GNU tac `open(2)`s a directory successfully and only fails at `read(2)`,
  # so EISDIR gets a template of its own rather than the open-failure one.
  defp read_error(file, %VFS.Error{kind: :eisdir}),
    do: "tac: #{file}: read error: Is a directory\n"

  defp read_error(file, error),
    do: "tac: failed to open '#{file}' for reading: #{FS.strerror(error)}\n"

  defp reverse_lines(content) do
    lines = String.split(content, "\n", trim: false)

    lines =
      if List.last(lines) == "" do
        List.delete_at(lines, -1)
      else
        lines
      end

    if lines == [] do
      ""
    else
      Enum.reverse(lines) |> Enum.join("\n") |> Kernel.<>("\n")
    end
  end
end
