defmodule JustBash.Commands.Find do
  @moduledoc "The `find` command - search for files in a directory hierarchy."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["find"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        paths = if opts.paths == [], do: ["."], else: opts.paths

        {results, stderr, exit_code} =
          Enum.reduce(paths, {[], "", 0}, fn path, {acc_results, acc_stderr, acc_code} ->
            resolved = InMemoryFs.resolve_path(bash.cwd, path)

            case find_recursive(bash.fs, resolved, path, opts, 0) do
              {:ok, found} ->
                {acc_results ++ found, acc_stderr, acc_code}

              {:error, msg} ->
                {acc_results, acc_stderr <> msg, 1}
            end
          end)

        output =
          if results == [] do
            ""
          else
            if opts.print0 do
              Enum.join(results, "\0") <> "\0"
            else
              Enum.join(results, "\n") <> "\n"
            end
          end

        {%{stdout: output, stderr: stderr, exit_code: exit_code}, bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      paths: [],
      name: nil,
      iname: nil,
      type: nil,
      maxdepth: nil,
      mindepth: nil,
      empty: false,
      print0: false
    })
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-name", pattern | rest], opts) do
    parse_args(rest, %{opts | name: pattern})
  end

  defp parse_args(["-iname", pattern | rest], opts) do
    parse_args(rest, %{opts | iname: pattern})
  end

  defp parse_args(["-type", type | rest], opts) when type in ["f", "d"] do
    parse_args(rest, %{opts | type: type})
  end

  defp parse_args(["-type", type | _rest], _opts) do
    {:error, "find: Unknown argument to -type: #{type}\n"}
  end

  defp parse_args(["-maxdepth", depth | rest], opts) do
    case Integer.parse(depth) do
      {d, ""} when d >= 0 -> parse_args(rest, %{opts | maxdepth: d})
      _ -> {:error, "find: Expected a positive decimal integer argument to -maxdepth\n"}
    end
  end

  defp parse_args(["-mindepth", depth | rest], opts) do
    case Integer.parse(depth) do
      {d, ""} when d >= 0 -> parse_args(rest, %{opts | mindepth: d})
      _ -> {:error, "find: Expected a positive decimal integer argument to -mindepth\n"}
    end
  end

  defp parse_args(["-empty" | rest], opts) do
    parse_args(rest, %{opts | empty: true})
  end

  defp parse_args(["-print" | rest], opts) do
    parse_args(rest, opts)
  end

  defp parse_args(["-print0" | rest], opts) do
    parse_args(rest, %{opts | print0: true})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "find: unknown predicate '#{arg}'\n"}
  end

  defp parse_args([path | rest], opts) do
    parse_args(rest, %{opts | paths: opts.paths ++ [path]})
  end

  defp find_recursive(fs, full_path, display_path, opts, depth) do
    if opts.maxdepth != nil and depth > opts.maxdepth do
      {:ok, []}
    else
      case InMemoryFs.stat(fs, full_path) do
        {:ok, stat} ->
          name = Path.basename(display_path)

          matches =
            if opts.mindepth == nil or depth >= opts.mindepth do
              matches_criteria?(name, display_path, stat, opts)
            else
              false
            end

          current = if matches, do: [display_path], else: []

          if stat.is_directory do
            case InMemoryFs.readdir(fs, full_path) do
              {:ok, entries} ->
                children =
                  Enum.flat_map(entries, fn entry ->
                    child_full =
                      if full_path == "/", do: "/#{entry}", else: "#{full_path}/#{entry}"

                    child_display =
                      if display_path == "." do
                        "./#{entry}"
                      else
                        "#{display_path}/#{entry}"
                      end

                    case find_recursive(fs, child_full, child_display, opts, depth + 1) do
                      {:ok, found} -> found
                      {:error, _} -> []
                    end
                  end)

                {:ok, current ++ children}

              {:error, _} ->
                {:ok, current}
            end
          else
            {:ok, current}
          end

        {:error, _} ->
          {:error, "find: #{display_path}: No such file or directory\n"}
      end
    end
  end

  defp matches_criteria?(name, _path, stat, opts) do
    name_match =
      cond do
        opts.name != nil -> glob_match?(name, opts.name, false)
        opts.iname != nil -> glob_match?(name, opts.iname, true)
        true -> true
      end

    type_match =
      case opts.type do
        "f" -> stat.is_file
        "d" -> stat.is_directory
        nil -> true
      end

    empty_match =
      if opts.empty do
        cond do
          stat.is_file -> stat.size == 0
          stat.is_directory -> true
          true -> false
        end
      else
        true
      end

    name_match and type_match and empty_match
  end

  defp glob_match?(name, pattern, ignore_case) do
    regex_pattern =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")
      |> String.replace("?", ".")
      |> then(fn p -> "^#{p}$" end)

    opts = if ignore_case, do: [:caseless], else: []

    case Regex.compile(regex_pattern, opts) do
      {:ok, regex} -> Regex.match?(regex, name)
      {:error, _} -> false
    end
  end
end
