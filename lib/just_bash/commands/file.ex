defmodule JustBash.Commands.File do
  @moduledoc "The `file` command - determine file type."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["file"]

  @impl true
  def execute(bash, args, _stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        if opts.files == [] do
          {Command.error("Usage: file [-bLi] FILE...\n"), bash}
        else
          {output, exit_code} = process_files(bash, opts)
          {%{stdout: output, stderr: "", exit_code: exit_code}, bash}
        end
    end
  end

  defp process_files(bash, opts) do
    Enum.reduce(opts.files, {"", 0}, fn file, {acc_out, acc_code} ->
      resolved = InMemoryFs.resolve_path(bash.cwd, file)

      case detect_type(bash, resolved, file) do
        {:ok, type_info} ->
          line = format_success_line(opts, file, type_info)
          {acc_out <> line, acc_code}

        {:error, _} ->
          line = format_error_line(opts, file)
          {acc_out <> line, 1}
      end
    end)
  end

  defp format_success_line(opts, file, type_info) do
    result = if opts.mime, do: type_info.mime, else: type_info.description
    if opts.brief, do: "#{result}\n", else: "#{file}: #{result}\n"
  end

  defp format_error_line(opts, file) do
    if opts.brief do
      "cannot open\n"
    else
      "#{file}: cannot open (No such file or directory)\n"
    end
  end

  defp parse_args(args) do
    parse_args(args, %{brief: false, mime: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-b" | rest], opts) do
    parse_args(rest, %{opts | brief: true})
  end

  defp parse_args(["--brief" | rest], opts) do
    parse_args(rest, %{opts | brief: true})
  end

  defp parse_args(["-i" | rest], opts) do
    parse_args(rest, %{opts | mime: true})
  end

  defp parse_args(["--mime" | rest], opts) do
    parse_args(rest, %{opts | mime: true})
  end

  defp parse_args(["--mime-type" | rest], opts) do
    parse_args(rest, %{opts | mime: true})
  end

  defp parse_args(["-L" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["--dereference" | rest], opts), do: parse_args(rest, opts)

  defp parse_args(["-bi" | rest], opts) do
    parse_args(rest, %{opts | brief: true, mime: true})
  end

  defp parse_args(["-ib" | rest], opts) do
    parse_args(rest, %{opts | brief: true, mime: true})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "file: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp detect_type(bash, path, filename) do
    case InMemoryFs.stat(bash.fs, path) do
      {:ok, %{is_directory: true}} ->
        {:ok, %{description: "directory", mime: "inode/directory"}}

      {:ok, %{is_file: true}} ->
        case InMemoryFs.read_file(bash, path) do
          {:ok, content, _new_bash} ->
            {:ok, detect_content_type(content, filename)}

          {:error, _} ->
            {:error, :read_error}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp detect_content_type("", _filename) do
    %{description: "empty", mime: "inode/x-empty"}
  end

  defp detect_content_type(content, filename) do
    cond do
      String.starts_with?(content, "#!/") ->
        detect_shebang(content)

      String.starts_with?(String.trim_leading(content), "<?xml") ->
        %{description: "XML document", mime: "application/xml"}

      String.starts_with?(String.downcase(String.trim_leading(content)), "<!doctype html") or
          String.starts_with?(String.downcase(String.trim_leading(content)), "<html") ->
        %{description: "HTML document", mime: "text/html"}

      binary_content?(content) ->
        %{description: "data", mime: "application/octet-stream"}

      true ->
        detect_text_type(content, filename)
    end
  end

  defp detect_shebang(content) do
    first_line = content |> String.split("\n") |> hd()

    cond do
      String.contains?(first_line, "python") ->
        %{description: "Python script, ASCII text executable", mime: "text/x-python"}

      String.contains?(first_line, "node") or String.contains?(first_line, "bun") ->
        %{description: "JavaScript script, ASCII text executable", mime: "text/javascript"}

      String.contains?(first_line, "bash") ->
        %{
          description: "Bourne-Again shell script, ASCII text executable",
          mime: "text/x-shellscript"
        }

      String.contains?(first_line, "sh") ->
        %{description: "POSIX shell script, ASCII text executable", mime: "text/x-shellscript"}

      String.contains?(first_line, "ruby") ->
        %{description: "Ruby script, ASCII text executable", mime: "text/x-ruby"}

      String.contains?(first_line, "perl") ->
        %{description: "Perl script, ASCII text executable", mime: "text/x-perl"}

      true ->
        %{description: "script, ASCII text executable", mime: "text/plain"}
    end
  end

  @extension_types %{
    ".js" => %{description: "JavaScript source", mime: "text/javascript"},
    ".ts" => %{description: "TypeScript source", mime: "text/typescript"},
    ".py" => %{description: "Python script", mime: "text/x-python"},
    ".rb" => %{description: "Ruby script", mime: "text/x-ruby"},
    ".sh" => %{description: "Bourne-Again shell script", mime: "text/x-shellscript"},
    ".json" => %{description: "JSON data", mime: "application/json"},
    ".yaml" => %{description: "YAML data", mime: "text/yaml"},
    ".yml" => %{description: "YAML data", mime: "text/yaml"},
    ".xml" => %{description: "XML document", mime: "application/xml"},
    ".html" => %{description: "HTML document", mime: "text/html"},
    ".htm" => %{description: "HTML document", mime: "text/html"},
    ".css" => %{description: "CSS stylesheet", mime: "text/css"},
    ".md" => %{description: "Markdown document", mime: "text/markdown"},
    ".txt" => %{description: "ASCII text", mime: "text/plain"},
    ".c" => %{description: "C source", mime: "text/x-c"},
    ".h" => %{description: "C header", mime: "text/x-c"},
    ".ex" => %{description: "Elixir source", mime: "text/x-elixir"},
    ".exs" => %{description: "Elixir script", mime: "text/x-elixir"}
  }

  defp detect_text_type(content, filename) do
    ext = Path.extname(filename) |> String.downcase()

    case Map.get(@extension_types, ext) do
      nil -> detect_fallback_type(content)
      type -> type
    end
  end

  defp detect_fallback_type(content) do
    if String.printable?(content) do
      %{description: "ASCII text", mime: "text/plain"}
    else
      %{description: "data", mime: "application/octet-stream"}
    end
  end

  defp binary_content?(content) do
    content
    |> String.to_charlist()
    |> Enum.take(512)
    |> Enum.any?(fn c -> c == 0 end)
  end
end
