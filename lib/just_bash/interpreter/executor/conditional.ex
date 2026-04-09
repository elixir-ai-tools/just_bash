defmodule JustBash.Interpreter.Executor.Conditional do
  @moduledoc """
  Evaluates conditional expressions for `[[ ]]` and `if` statements.

  Supports:
  - Unary file tests: -e, -f, -d, -r, -w, -x, -s, -L, -h, etc.
  - Unary string tests: -z, -n
  - Binary string comparisons: =, ==, !=, <, >
  - Binary integer comparisons: -eq, -ne, -lt, -le, -gt, -ge
  - Binary file comparisons: -nt, -ot, -ef
  - Pattern matching: ==, =~
  - Logical operators: &&, ||, !
  """

  alias JustBash.AST
  alias JustBash.Fs
  alias JustBash.Interpreter.Expansion
  alias JustBash.Limit

  @type unary_op_type ::
          :file_exists
          | :regular_file
          | :directory
          | :file_size
          | :string_empty
          | :string_non_empty
          | :symlink
          | :var_set
          | :always_false

  @doc """
  Evaluate a conditional expression AST node.
  Returns `{result, updated_bash}` where result is `true` or `false`.
  The bash struct may be updated (e.g. `BASH_REMATCH` after `=~`).
  """
  @spec evaluate(JustBash.t(), AST.conditional_expression()) :: {boolean(), JustBash.t()}
  def evaluate(bash, %AST.CondWord{word: word}) do
    value = Expansion.expand_word_parts_simple(bash, word.parts)
    {value != "", bash}
  end

  def evaluate(bash, %AST.CondNot{operand: operand}) do
    {result, bash} = evaluate(bash, operand)
    {not result, bash}
  end

  def evaluate(bash, %AST.CondAnd{left: left, right: right}) do
    {left_result, bash} = evaluate(bash, left)

    if left_result do
      evaluate(bash, right)
    else
      {false, bash}
    end
  end

  def evaluate(bash, %AST.CondOr{left: left, right: right}) do
    {left_result, bash} = evaluate(bash, left)

    if left_result do
      {true, bash}
    else
      evaluate(bash, right)
    end
  end

  def evaluate(bash, %AST.CondGroup{expression: expr}) do
    evaluate(bash, expr)
  end

  def evaluate(bash, %AST.CondUnary{operator: op, operand: word}) do
    path = Expansion.expand_word_parts_simple(bash, word.parts)
    resolved = Fs.resolve_path(bash.cwd, path)
    {evaluate_unary(bash, op, path, resolved), bash}
  end

  def evaluate(bash, %AST.CondBinary{operator: op, left: left_word, right: right_word}) do
    left = Expansion.expand_word_parts_simple(bash, left_word.parts)
    right = Expansion.expand_word_parts_simple(bash, right_word.parts)
    evaluate_binary(bash, op, left, right)
  end

  # --- Unary Operators ---

  defp evaluate_unary(bash, op, path, resolved) do
    evaluate_unary_by_type(unary_op_type(op), bash, path, resolved)
  end

  defp evaluate_unary_by_type(:file_exists, bash, _path, resolved),
    do: file_exists?(bash, resolved)

  defp evaluate_unary_by_type(:regular_file, bash, _path, resolved),
    do: regular_file?(bash, resolved)

  defp evaluate_unary_by_type(:directory, bash, _path, resolved),
    do: directory?(bash, resolved)

  defp evaluate_unary_by_type(:file_size, bash, _path, resolved),
    do: file_size_gt_zero?(bash, resolved)

  defp evaluate_unary_by_type(:string_empty, _bash, path, _resolved),
    do: path == ""

  defp evaluate_unary_by_type(:string_non_empty, _bash, path, _resolved),
    do: path != ""

  defp evaluate_unary_by_type(:symlink, bash, _path, resolved),
    do: symlink?(bash, resolved)

  defp evaluate_unary_by_type(:always_false, _bash, _path, _resolved),
    do: false

  defp evaluate_unary_by_type(:var_set, bash, path, _resolved),
    do: Map.has_key?(bash.env, path)

  @spec unary_op_type(atom()) :: unary_op_type()
  defp unary_op_type(:"-e"), do: :file_exists
  defp unary_op_type(:"-a"), do: :file_exists
  defp unary_op_type(:"-f"), do: :regular_file
  defp unary_op_type(:"-d"), do: :directory
  defp unary_op_type(:"-r"), do: :file_exists
  defp unary_op_type(:"-w"), do: :file_exists
  defp unary_op_type(:"-x"), do: :file_exists
  defp unary_op_type(:"-s"), do: :file_size
  defp unary_op_type(:"-z"), do: :string_empty
  defp unary_op_type(:"-n"), do: :string_non_empty
  defp unary_op_type(:"-L"), do: :symlink
  defp unary_op_type(:"-h"), do: :symlink
  defp unary_op_type(:"-O"), do: :file_exists
  defp unary_op_type(:"-G"), do: :file_exists
  defp unary_op_type(:"-N"), do: :file_exists
  defp unary_op_type(:"-v"), do: :var_set
  # Device/socket tests always false in virtual fs
  defp unary_op_type(:"-b"), do: :always_false
  defp unary_op_type(:"-c"), do: :always_false
  defp unary_op_type(:"-p"), do: :always_false
  defp unary_op_type(:"-S"), do: :always_false
  defp unary_op_type(:"-t"), do: :always_false
  defp unary_op_type(:"-g"), do: :always_false
  defp unary_op_type(:"-u"), do: :always_false
  defp unary_op_type(:"-k"), do: :always_false
  defp unary_op_type(_), do: :always_false

  # --- Binary Operators ---

  defp evaluate_binary(bash, op, left, right) do
    case binary_op_type(op) do
      :integer_comparison -> {evaluate_integer_comparison(op, left, right), bash}
      :file_comparison -> {evaluate_file_comparison(bash, op, left, right), bash}
      :regex_match -> evaluate_regex_match(bash, left, right)
      :string_comparison -> {evaluate_string_comparison(op, left, right), bash}
    end
  end

  defp binary_op_type(op) when op in [:"-eq", :"-ne", :"-lt", :"-le", :"-gt", :"-ge"],
    do: :integer_comparison

  defp binary_op_type(op) when op in [:"-nt", :"-ot", :"-ef"], do: :file_comparison
  defp binary_op_type(:=~), do: :regex_match
  defp binary_op_type(_), do: :string_comparison

  defp evaluate_integer_comparison(:"-eq", left, right),
    do: parse_int(left) == parse_int(right)

  defp evaluate_integer_comparison(:"-ne", left, right),
    do: parse_int(left) != parse_int(right)

  defp evaluate_integer_comparison(:"-lt", left, right),
    do: parse_int(left) < parse_int(right)

  defp evaluate_integer_comparison(:"-le", left, right),
    do: parse_int(left) <= parse_int(right)

  defp evaluate_integer_comparison(:"-gt", left, right),
    do: parse_int(left) > parse_int(right)

  defp evaluate_integer_comparison(:"-ge", left, right),
    do: parse_int(left) >= parse_int(right)

  defp evaluate_file_comparison(bash, :"-nt", left, right), do: file_newer?(bash, left, right)
  defp evaluate_file_comparison(bash, :"-ot", left, right), do: file_newer?(bash, right, left)
  defp evaluate_file_comparison(bash, :"-ef", left, right), do: same_file?(bash, left, right)

  defp evaluate_string_comparison(:=, left, right), do: left == right
  defp evaluate_string_comparison(:==, left, right), do: pattern_match?(left, right)
  defp evaluate_string_comparison(:!=, left, right), do: not pattern_match?(left, right)
  defp evaluate_string_comparison(:<, left, right), do: left < right
  defp evaluate_string_comparison(:>, left, right), do: left > right
  defp evaluate_string_comparison(_, _left, _right), do: false

  # --- Helper Functions ---

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp pattern_match?(str, pattern) do
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("^" <> regex_pattern <> "$") do
      {:ok, regex} -> Regex.match?(regex, str)
      {:error, _} -> str == pattern
    end
  end

  # Evaluate =~ regex match and populate BASH_REMATCH
  defp evaluate_regex_match(bash, str, pattern) do
    case Limit.compile_regex(bash.limits, pattern) do
      {:ok, regex} ->
        case Regex.run(regex, str) do
          nil ->
            {false, clear_bash_rematch(bash)}

          matches ->
            {true, set_bash_rematch(bash, matches)}
        end

      {:error, _} ->
        {false, clear_bash_rematch(bash)}
    end
  end

  # Set BASH_REMATCH[0], BASH_REMATCH[1], etc. from regex match results
  defp set_bash_rematch(bash, matches) do
    env = clear_bash_rematch_env(bash.env)

    env =
      matches
      |> Enum.with_index()
      |> Enum.reduce(env, fn {value, idx}, acc ->
        Map.put(acc, "BASH_REMATCH[#{idx}]", value)
      end)

    %{bash | env: env}
  end

  # Clear all BASH_REMATCH entries from env
  defp clear_bash_rematch(bash) do
    %{bash | env: clear_bash_rematch_env(bash.env)}
  end

  defp clear_bash_rematch_env(env) do
    Enum.reject(env, fn {key, _} -> String.starts_with?(key, "BASH_REMATCH[") end)
    |> Map.new()
  end

  # --- File System Helpers ---

  defp file_exists?(bash, path) do
    case Fs.stat(bash.fs, path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp regular_file?(bash, path) do
    case Fs.stat(bash.fs, path) do
      {:ok, stat} -> stat.is_file
      {:error, _} -> false
    end
  end

  defp directory?(bash, path) do
    case Fs.stat(bash.fs, path) do
      {:ok, stat} -> stat.is_directory
      {:error, _} -> false
    end
  end

  defp file_size_gt_zero?(bash, path) do
    case Fs.stat(bash.fs, path) do
      {:ok, stat} -> stat.size > 0
      {:error, _} -> false
    end
  end

  defp symlink?(bash, path) do
    case Fs.lstat(bash.fs, path) do
      {:ok, stat} -> stat.is_symbolic_link
      {:error, _} -> false
    end
  end

  defp file_newer?(bash, path1, path2) do
    with {:ok, stat1} <- Fs.stat(bash.fs, path1),
         {:ok, stat2} <- Fs.stat(bash.fs, path2) do
      stat1.mtime > stat2.mtime
    else
      _ -> false
    end
  end

  defp same_file?(bash, path1, path2) do
    resolved1 = Fs.resolve_path(bash.cwd, path1)
    resolved2 = Fs.resolve_path(bash.cwd, path2)
    resolved1 == resolved2
  end
end
