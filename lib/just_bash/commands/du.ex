defmodule JustBash.Commands.Du do
  @moduledoc "The `du` command - estimate file space usage."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["du"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        targets = if opts.files == [], do: ["."], else: opts.files

        {output, stderr, grand_total} =
          Enum.reduce(targets, {"", "", 0}, fn target, {acc_out, acc_err, acc_total} ->
            resolved = InMemoryFs.resolve_path(bash.cwd, target)

            case calculate_size(bash.fs, resolved, target, opts, 0) do
              {:ok, out, size} ->
                {acc_out <> out, acc_err, acc_total + size}

              {:error, msg} ->
                {acc_out, acc_err <> msg, acc_total}
            end
          end)

        output =
          if opts.grand_total and length(targets) > 0 do
            output <> "#{format_size(grand_total, opts.human_readable)}\ttotal\n"
          else
            output
          end

        exit_code = if stderr != "", do: 1, else: 0
        {%{stdout: output, stderr: stderr, exit_code: exit_code}, bash}
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      all_files: false,
      human_readable: false,
      summarize: false,
      grand_total: false,
      max_depth: nil,
      files: []
    })
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-a" | rest], opts) do
    parse_args(rest, %{opts | all_files: true})
  end

  defp parse_args(["-h" | rest], opts) do
    parse_args(rest, %{opts | human_readable: true})
  end

  defp parse_args(["-s" | rest], opts) do
    parse_args(rest, %{opts | summarize: true})
  end

  defp parse_args(["-c" | rest], opts) do
    parse_args(rest, %{opts | grand_total: true})
  end

  defp parse_args(["--max-depth=" <> depth | rest], opts) do
    case Integer.parse(depth) do
      {d, ""} when d >= 0 -> parse_args(rest, %{opts | max_depth: d})
      _ -> {:error, "du: invalid maximum depth '#{depth}'\n"}
    end
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "du: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp calculate_size(fs, path, display_path, opts, depth) do
    case InMemoryFs.stat(fs, path) do
      {:ok, %{is_directory: false, size: size}} ->
        output =
          if opts.all_files or depth == 0 do
            "#{format_size(size, opts.human_readable)}\t#{display_path}\n"
          else
            ""
          end

        {:ok, output, size}

      {:ok, %{is_directory: true}} ->
        case InMemoryFs.readdir(fs, path) do
          {:ok, entries} ->
            {output, dir_size} =
              Enum.reduce(entries, {"", 0}, fn entry, {acc_out, acc_size} ->
                entry_path = if path == "/", do: "/#{entry}", else: "#{path}/#{entry}"

                entry_display =
                  if display_path == ".", do: entry, else: "#{display_path}/#{entry}"

                case InMemoryFs.stat(fs, entry_path) do
                  {:ok, %{is_directory: true}} ->
                    case calculate_size(fs, entry_path, entry_display, opts, depth + 1) do
                      {:ok, sub_out, sub_size} ->
                        out =
                          if not opts.summarize and
                               (opts.max_depth == nil or depth + 1 <= opts.max_depth) do
                            sub_out
                          else
                            ""
                          end

                        {acc_out <> out, acc_size + sub_size}

                      {:error, _} ->
                        {acc_out, acc_size}
                    end

                  {:ok, %{is_file: true, size: size}} ->
                    out =
                      if opts.all_files and not opts.summarize do
                        "#{format_size(size, opts.human_readable)}\t#{entry_display}\n"
                      else
                        ""
                      end

                    {acc_out <> out, acc_size + size}

                  _ ->
                    {acc_out, acc_size}
                end
              end)

            final_output =
              if opts.summarize or opts.max_depth == nil or depth <= opts.max_depth do
                output <> "#{format_size(dir_size, opts.human_readable)}\t#{display_path}\n"
              else
                output
              end

            {:ok, final_output, dir_size}

          {:error, _} ->
            {:error, "du: cannot read directory '#{display_path}': Permission denied\n"}
        end

      {:error, _} ->
        {:error, "du: cannot access '#{display_path}': No such file or directory\n"}
    end
  end

  defp format_size(bytes, false) do
    max(div(bytes + 1023, 1024), 1) |> Integer.to_string()
  end

  defp format_size(bytes, true) do
    cond do
      bytes < 1024 -> "#{bytes}"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)}K"
      bytes < 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 1)}M"
      true -> "#{Float.round(bytes / (1024 * 1024 * 1024), 1)}G"
    end
  end
end
