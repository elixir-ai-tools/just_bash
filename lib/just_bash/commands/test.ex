defmodule JustBash.Commands.Test do
  @moduledoc "The `test` and `[` commands - evaluate conditional expressions."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["test", "["]

  @impl true
  def execute(bash, args, _stdin) do
    args = strip_bracket(args)
    exit_code = evaluate(bash, args)
    {Command.result("", "", exit_code), bash}
  end

  defp strip_bracket(args) do
    if List.last(args) == "]" do
      Enum.slice(args, 0..-2//1)
    else
      args
    end
  end

  defp evaluate(_bash, []), do: 1

  defp evaluate(_bash, [arg]) do
    if arg != "", do: 0, else: 1
  end

  defp evaluate(bash, [op, arg]) do
    case op do
      "-z" -> if arg == "", do: 0, else: 1
      "-n" -> if arg != "", do: 0, else: 1
      "-e" -> if file_exists?(bash, arg), do: 0, else: 1
      "-f" -> if file?(bash, arg), do: 0, else: 1
      "-d" -> if directory?(bash, arg), do: 0, else: 1
      "-r" -> if file_exists?(bash, arg), do: 0, else: 1
      "-w" -> if file_exists?(bash, arg), do: 0, else: 1
      "-x" -> if file_exists?(bash, arg), do: 0, else: 1
      "-s" -> if file_has_size?(bash, arg), do: 0, else: 1
      "-L" -> if symlink?(bash, arg), do: 0, else: 1
      "-h" -> if symlink?(bash, arg), do: 0, else: 1
      "!" -> if arg == "", do: 0, else: 1
      _ -> 1
    end
  end

  defp evaluate(bash, [left, op, right]) do
    case op do
      "=" ->
        if left == right, do: 0, else: 1

      "==" ->
        if left == right, do: 0, else: 1

      "!=" ->
        if left != right, do: 0, else: 1

      "-eq" ->
        numeric_compare(left, right, &==/2)

      "-ne" ->
        numeric_compare(left, right, &!=/2)

      "-lt" ->
        numeric_compare(left, right, &</2)

      "-le" ->
        numeric_compare(left, right, &<=/2)

      "-gt" ->
        numeric_compare(left, right, &>/2)

      "-ge" ->
        numeric_compare(left, right, &>=/2)

      "<" ->
        if left < right, do: 0, else: 1

      ">" ->
        if left > right, do: 0, else: 1

      "-a" ->
        if left != "" and right != "", do: 0, else: 1

      "-o" ->
        if left != "" or right != "", do: 0, else: 1

      _ ->
        if left == "!" do
          result = evaluate(bash, [op, right])
          if result == 0, do: 1, else: 0
        else
          1
        end
    end
  end

  defp evaluate(bash, ["!" | rest]) do
    result = evaluate(bash, rest)
    if result == 0, do: 1, else: 0
  end

  defp evaluate(_bash, _args), do: 1

  defp numeric_compare(left, right, compare_fn) do
    case {Integer.parse(left), Integer.parse(right)} do
      {{left_num, _}, {right_num, _}} ->
        if compare_fn.(left_num, right_num), do: 0, else: 1

      _ ->
        2
    end
  end

  defp file_exists?(bash, path) do
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.stat(bash.fs, resolved) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp file?(bash, path) do
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.stat(bash.fs, resolved) do
      {:ok, %{is_file: true}} -> true
      _ -> false
    end
  end

  defp directory?(bash, path) do
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.stat(bash.fs, resolved) do
      {:ok, %{is_directory: true}} -> true
      _ -> false
    end
  end

  defp symlink?(bash, path) do
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.stat(bash.fs, resolved) do
      {:ok, %{is_symlink: true}} -> true
      _ -> false
    end
  end

  defp file_has_size?(bash, path) do
    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    case InMemoryFs.stat(bash.fs, resolved) do
      {:ok, %{size: size}} when size > 0 -> true
      _ -> false
    end
  end
end
