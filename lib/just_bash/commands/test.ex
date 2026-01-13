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
    bool_to_exit(arg != "")
  end

  defp evaluate(bash, [op, arg]) do
    evaluate_unary(bash, op, arg)
  end

  defp evaluate(bash, [left, op, right]) do
    evaluate_binary(bash, left, op, right)
  end

  defp evaluate(bash, ["!" | rest]) do
    negate(evaluate(bash, rest))
  end

  defp evaluate(_bash, _args), do: 1

  defp evaluate_unary(_bash, "-z", arg), do: bool_to_exit(arg == "")
  defp evaluate_unary(_bash, "-n", arg), do: bool_to_exit(arg != "")
  defp evaluate_unary(bash, "-e", arg), do: bool_to_exit(file_exists?(bash, arg))
  defp evaluate_unary(bash, "-f", arg), do: bool_to_exit(file?(bash, arg))
  defp evaluate_unary(bash, "-d", arg), do: bool_to_exit(directory?(bash, arg))
  defp evaluate_unary(bash, "-r", arg), do: bool_to_exit(file_exists?(bash, arg))
  defp evaluate_unary(bash, "-w", arg), do: bool_to_exit(file_exists?(bash, arg))
  defp evaluate_unary(bash, "-x", arg), do: bool_to_exit(file_exists?(bash, arg))
  defp evaluate_unary(bash, "-s", arg), do: bool_to_exit(file_has_size?(bash, arg))
  defp evaluate_unary(bash, "-L", arg), do: bool_to_exit(symlink?(bash, arg))
  defp evaluate_unary(bash, "-h", arg), do: bool_to_exit(symlink?(bash, arg))
  defp evaluate_unary(_bash, "!", arg), do: bool_to_exit(arg == "")
  defp evaluate_unary(_bash, _op, _arg), do: 1

  defp evaluate_binary(_bash, left, "=", right), do: bool_to_exit(left == right)
  defp evaluate_binary(_bash, left, "==", right), do: bool_to_exit(left == right)
  defp evaluate_binary(_bash, left, "!=", right), do: bool_to_exit(left != right)
  defp evaluate_binary(_bash, left, "-eq", right), do: numeric_compare(left, right, &==/2)
  defp evaluate_binary(_bash, left, "-ne", right), do: numeric_compare(left, right, &!=/2)
  defp evaluate_binary(_bash, left, "-lt", right), do: numeric_compare(left, right, &</2)
  defp evaluate_binary(_bash, left, "-le", right), do: numeric_compare(left, right, &<=/2)
  defp evaluate_binary(_bash, left, "-gt", right), do: numeric_compare(left, right, &>/2)
  defp evaluate_binary(_bash, left, "-ge", right), do: numeric_compare(left, right, &>=/2)
  defp evaluate_binary(_bash, left, "<", right), do: bool_to_exit(left < right)
  defp evaluate_binary(_bash, left, ">", right), do: bool_to_exit(left > right)
  defp evaluate_binary(_bash, left, "-a", right), do: bool_to_exit(left != "" and right != "")
  defp evaluate_binary(_bash, left, "-o", right), do: bool_to_exit(left != "" or right != "")
  defp evaluate_binary(bash, "!", op, right), do: negate(evaluate(bash, [op, right]))
  defp evaluate_binary(_bash, _left, _op, _right), do: 1

  defp bool_to_exit(true), do: 0
  defp bool_to_exit(false), do: 1

  defp negate(0), do: 1
  defp negate(_), do: 0

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

    case InMemoryFs.lstat(bash.fs, resolved) do
      {:ok, %{is_symbolic_link: true}} -> true
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
