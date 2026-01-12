defmodule JustBash.Commands.Comm do
  @moduledoc "The `comm` command - compare two sorted files line by line."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["comm"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        if length(opts.files) != 2 do
          {Command.error("comm: missing operand\nTry 'comm --help' for more information.\n"),
           bash}
        else
          [file1, file2] = opts.files

          with {:ok, content1} <- read_file(bash, file1, stdin),
               {:ok, content2} <- read_file(bash, file2, stdin) do
            lines1 = split_lines(content1)
            lines2 = split_lines(content2)
            output = compare_files(lines1, lines2, opts)
            {Command.ok(output), bash}
          else
            {:error, msg} -> {Command.error(msg), bash}
          end
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{suppress1: false, suppress2: false, suppress3: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-1" | rest], opts) do
    parse_args(rest, %{opts | suppress1: true})
  end

  defp parse_args(["-2" | rest], opts) do
    parse_args(rest, %{opts | suppress2: true})
  end

  defp parse_args(["-3" | rest], opts) do
    parse_args(rest, %{opts | suppress3: true})
  end

  defp parse_args(["-12" | rest], opts) do
    parse_args(rest, %{opts | suppress1: true, suppress2: true})
  end

  defp parse_args(["-21" | rest], opts) do
    parse_args(rest, %{opts | suppress1: true, suppress2: true})
  end

  defp parse_args(["-13" | rest], opts) do
    parse_args(rest, %{opts | suppress1: true, suppress3: true})
  end

  defp parse_args(["-31" | rest], opts) do
    parse_args(rest, %{opts | suppress1: true, suppress3: true})
  end

  defp parse_args(["-23" | rest], opts) do
    parse_args(rest, %{opts | suppress2: true, suppress3: true})
  end

  defp parse_args(["-32" | rest], opts) do
    parse_args(rest, %{opts | suppress2: true, suppress3: true})
  end

  defp parse_args(["-123" | rest], opts) do
    parse_args(rest, %{opts | suppress1: true, suppress2: true, suppress3: true})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "comm: invalid option -- '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp read_file(_bash, "-", stdin), do: {:ok, stdin}

  defp read_file(bash, file, _stdin) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, "comm: #{file}: No such file or directory\n"}
    end
  end

  defp split_lines(content) do
    lines = String.split(content, "\n", trim: false)

    if List.last(lines) == "" do
      List.delete_at(lines, -1)
    else
      lines
    end
  end

  defp compare_files(lines1, lines2, opts) do
    col2_prefix = if opts.suppress1, do: "", else: "\t"
    col3_prefix = col2_prefix <> if opts.suppress2, do: "", else: "\t"

    do_compare(lines1, lines2, opts, col2_prefix, col3_prefix, [])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp do_compare([], [], _opts, _col2, _col3, acc), do: acc

  defp do_compare([], [h2 | t2], opts, col2, col3, acc) do
    new_acc =
      if opts.suppress2 do
        acc
      else
        ["#{col2}#{h2}\n" | acc]
      end

    do_compare([], t2, opts, col2, col3, new_acc)
  end

  defp do_compare([h1 | t1], [], opts, col2, col3, acc) do
    new_acc =
      if opts.suppress1 do
        acc
      else
        ["#{h1}\n" | acc]
      end

    do_compare(t1, [], opts, col2, col3, new_acc)
  end

  defp do_compare([h1 | t1] = l1, [h2 | t2] = l2, opts, col2, col3, acc) do
    cond do
      h1 < h2 ->
        new_acc = if opts.suppress1, do: acc, else: ["#{h1}\n" | acc]
        do_compare(t1, l2, opts, col2, col3, new_acc)

      h1 > h2 ->
        new_acc = if opts.suppress2, do: acc, else: ["#{col2}#{h2}\n" | acc]
        do_compare(l1, t2, opts, col2, col3, new_acc)

      true ->
        new_acc = if opts.suppress3, do: acc, else: ["#{col3}#{h1}\n" | acc]
        do_compare(t1, t2, opts, col2, col3, new_acc)
    end
  end
end
