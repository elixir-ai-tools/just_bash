defmodule JustBash.Commands.StdinOperand do
  @moduledoc """
  The `-` file operand.

  POSIX gives every utility that takes a file operand the same reading of a
  bare `-`: it names standard input, not a file called `-`. Resolving it as a
  path instead reaches the filesystem, where it does not exist — harmless
  while the read paths failed silently, and a hard error the moment #70 taught
  them to report the read they could not do.

  `sort -`, `uniq -` and `grep pat -` are the shapes that matter: they are how
  a pipeline names its own input when it also wants to name a file, and under
  `set -o pipefail` a diagnostic there kills the pipeline.
  """

  alias JustBash.FS

  @dash "-"

  @doc """
  True when a file operand names standard input rather than a path.
  """
  @spec stdin?(String.t()) :: boolean()
  def stdin?(@dash), do: true
  def stdin?(_operand), do: false

  @doc """
  Read a file operand, taking `-` as `stdin` rather than resolving it as a
  path. Mirrors `JustBash.FS.read_file/2`, so the error arm a caller already
  has for a real path keeps working unchanged.
  """
  @spec read(FS.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, binary(), FS.t()} | {:error, VFS.Error.t()}
  def read(fs, _cwd, @dash, stdin), do: {:ok, stdin || "", fs}
  def read(fs, cwd, operand, _stdin), do: FS.read_file(fs, FS.resolve_path(cwd, operand))

  @doc """
  Split a command's arguments into its file operands, honouring `--`.

  `Enum.reject(args, &String.starts_with?(&1, "-"))` is not that split. It
  deletes `-`, which is an operand naming stdin and never an option, and it
  deletes every operand after `--`, which is the only way to name a file whose
  name begins with a dash. Both deletions are silent: the command reads one
  fewer input than it was given and still exits 0.
  """
  @spec operands([String.t()]) :: [String.t()]
  def operands(args), do: do_operands(args, [])

  defp do_operands([], acc), do: Enum.reverse(acc)
  defp do_operands(["--" | rest], acc), do: Enum.reverse(acc, rest)
  defp do_operands([@dash | rest], acc), do: do_operands(rest, [@dash | acc])
  defp do_operands([@dash <> _ | rest], acc), do: do_operands(rest, acc)
  defp do_operands([operand | rest], acc), do: do_operands(rest, [operand | acc])
end
