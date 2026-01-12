defmodule JustBash.Commands.Diff do
  @moduledoc "The `diff` command - compare files line by line."
  @behaviour JustBash.Commands.Command

  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["diff"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {%{stdout: "", stderr: msg, exit_code: 2}, bash}

      {:ok, opts} ->
        if length(opts.files) < 2 do
          {%{stdout: "", stderr: "diff: missing operand\n", exit_code: 2}, bash}
        else
          [file1, file2] = Enum.take(opts.files, 2)

          with {:ok, content1} <- read_file(bash, file1, stdin),
               {:ok, content2} <- read_file(bash, file2, stdin) do
            {result, _} = compare_contents(content1, content2, file1, file2, opts)
            {result, bash}
          else
            {:error, file} ->
              {%{stdout: "", stderr: "diff: #{file}: No such file or directory\n", exit_code: 2},
               bash}
          end
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      unified: false,
      brief: false,
      report_same: false,
      ignore_case: false,
      files: []
    })
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-u" | rest], opts) do
    parse_args(rest, %{opts | unified: true})
  end

  defp parse_args(["--unified" | rest], opts) do
    parse_args(rest, %{opts | unified: true})
  end

  defp parse_args(["-q" | rest], opts) do
    parse_args(rest, %{opts | brief: true})
  end

  defp parse_args(["--brief" | rest], opts) do
    parse_args(rest, %{opts | brief: true})
  end

  defp parse_args(["-s" | rest], opts) do
    parse_args(rest, %{opts | report_same: true})
  end

  defp parse_args(["--report-identical-files" | rest], opts) do
    parse_args(rest, %{opts | report_same: true})
  end

  defp parse_args(["-i" | rest], opts) do
    parse_args(rest, %{opts | ignore_case: true})
  end

  defp parse_args(["--ignore-case" | rest], opts) do
    parse_args(rest, %{opts | ignore_case: true})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "diff: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp read_file(_bash, "-", stdin), do: {:ok, stdin}

  defp read_file(bash, file, _stdin) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, file}
    end
  end

  defp compare_contents(content1, content2, file1, file2, opts) do
    c1 = if opts.ignore_case, do: String.downcase(content1), else: content1
    c2 = if opts.ignore_case, do: String.downcase(content2), else: content2

    if c1 == c2 do
      if opts.report_same do
        {%{stdout: "Files #{file1} and #{file2} are identical\n", stderr: "", exit_code: 0}, nil}
      else
        {%{stdout: "", stderr: "", exit_code: 0}, nil}
      end
    else
      if opts.brief do
        {%{stdout: "Files #{file1} and #{file2} differ\n", stderr: "", exit_code: 1}, nil}
      else
        diff_output = generate_unified_diff(content1, content2, file1, file2)
        {%{stdout: diff_output, stderr: "", exit_code: 1}, nil}
      end
    end
  end

  defp generate_unified_diff(content1, content2, file1, file2) do
    lines1 = String.split(content1, "\n", trim: false)
    lines2 = String.split(content2, "\n", trim: false)

    lines1 = if List.last(lines1) == "", do: List.delete_at(lines1, -1), else: lines1
    lines2 = if List.last(lines2) == "", do: List.delete_at(lines2, -1), else: lines2

    hunks = compute_diff_hunks(lines1, lines2)

    if hunks == [] do
      ""
    else
      header = "--- #{file1}\n+++ #{file2}\n"
      header <> Enum.join(hunks, "")
    end
  end

  defp compute_diff_hunks(lines1, lines2) do
    lcs = compute_lcs(lines1, lines2)

    changes = build_changes(lines1, lines2, lcs)

    if changes == [] do
      []
    else
      format_hunks(changes, lines1, lines2)
    end
  end

  defp compute_lcs(list1, list2) do
    m = length(list1)
    n = length(list2)

    dp =
      for i <- 0..m, j <- 0..n, into: %{} do
        {{i, j}, 0}
      end

    dp =
      Enum.reduce(1..m, dp, fn i, dp_acc ->
        Enum.reduce(1..n, dp_acc, fn j, dp_inner ->
          if Enum.at(list1, i - 1) == Enum.at(list2, j - 1) do
            Map.put(dp_inner, {i, j}, Map.get(dp_inner, {i - 1, j - 1}) + 1)
          else
            Map.put(
              dp_inner,
              {i, j},
              max(Map.get(dp_inner, {i - 1, j}), Map.get(dp_inner, {i, j - 1}))
            )
          end
        end)
      end)

    backtrack_lcs(dp, list1, list2, m, n, [])
  end

  defp backtrack_lcs(_dp, _list1, _list2, 0, _j, acc), do: acc
  defp backtrack_lcs(_dp, _list1, _list2, _i, 0, acc), do: acc

  defp backtrack_lcs(dp, list1, list2, i, j, acc) do
    cond do
      Enum.at(list1, i - 1) == Enum.at(list2, j - 1) ->
        backtrack_lcs(dp, list1, list2, i - 1, j - 1, [
          {i - 1, j - 1, Enum.at(list1, i - 1)} | acc
        ])

      Map.get(dp, {i - 1, j}) > Map.get(dp, {i, j - 1}) ->
        backtrack_lcs(dp, list1, list2, i - 1, j, acc)

      true ->
        backtrack_lcs(dp, list1, list2, i, j - 1, acc)
    end
  end

  defp build_changes(lines1, lines2, lcs) do
    lcs_set1 = MapSet.new(Enum.map(lcs, fn {i, _, _} -> i end))
    lcs_set2 = MapSet.new(Enum.map(lcs, fn {_, j, _} -> j end))

    removed =
      lines1
      |> Enum.with_index()
      |> Enum.reject(fn {_, i} -> MapSet.member?(lcs_set1, i) end)
      |> Enum.map(fn {line, i} -> {:remove, i, line} end)

    added =
      lines2
      |> Enum.with_index()
      |> Enum.reject(fn {_, j} -> MapSet.member?(lcs_set2, j) end)
      |> Enum.map(fn {line, j} -> {:add, j, line} end)

    removed ++ added
  end

  defp format_hunks(changes, lines1, lines2) do
    if changes == [] do
      []
    else
      start1 = 1
      start2 = 1
      count1 = length(lines1)
      count2 = length(lines2)

      hunk_header = "@@ -#{start1},#{count1} +#{start2},#{count2} @@\n"

      removed_indices = MapSet.new(for {:remove, i, _} <- changes, do: i)
      _added_indices = MapSet.new(for {:add, j, _} <- changes, do: j)

      lines =
        Enum.map(Enum.with_index(lines1), fn {line, i} ->
          if MapSet.member?(removed_indices, i) do
            "-#{line}\n"
          else
            " #{line}\n"
          end
        end)

      added_lines =
        for {:add, _, line} <- Enum.sort_by(changes, fn {_, idx, _} -> idx end),
            do: "+#{line}\n"

      [hunk_header | lines ++ added_lines]
    end
  end
end
