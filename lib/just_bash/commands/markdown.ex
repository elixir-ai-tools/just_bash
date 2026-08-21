defmodule JustBash.Commands.Markdown do
  @moduledoc """
  The `markdown` (or `md`) command - convert Markdown to HTML.

  Uses MDEx for Markdown parsing and HTML generation.

  ## Examples

      # Convert file
      markdown README.md > readme.html

      # Pipe content
      echo "# Hello" | markdown

      # Process markdown from a variable
      echo "$content" | markdown > page.html
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["markdown", "md"]

  @impl true
  def execute(bash, args, stdin) do
    {:ok, opts} = parse_args(args)
    execute_with_opts(bash, opts, stdin)
  end

  defp execute_with_opts(bash, %{help: true}, _stdin) do
    help = """
    Usage: markdown [OPTIONS] [FILE]

    Convert Markdown to HTML.

    Options:
      --smartypants    Enable smart quotes and dashes
      --gfm            Enable GitHub Flavored Markdown (default)
      --no-gfm         Disable GitHub Flavored Markdown
      --breaks         Convert newlines to <br> tags
      --help           Show this help message

    If FILE is not provided, reads from stdin.

    Examples:
      markdown README.md
      echo "# Title" | markdown
      cat post.md | markdown > post.html
    """

    {Command.ok(help), bash}
  end

  defp execute_with_opts(bash, opts, stdin) do
    case get_content(bash, opts, stdin) do
      {:ok, content, bash} ->
        case render(content, opts) do
          {:ok, html} ->
            {Command.ok(html), bash}

          {:error, msg} ->
            {Command.error("markdown: #{msg}\n"), bash}
        end

      {:error, msg} ->
        {Command.error("markdown: #{msg}\n"), bash}
    end
  end

  defp get_content(bash, %{file: file}, _stdin) when is_binary(file) do
    resolved = FS.resolve_path(bash.cwd, file)

    case FS.read_file(bash.fs, resolved) do
      {:ok, content, fs} -> {:ok, content, %{bash | fs: fs}}
      {:error, _} -> {:error, "cannot read '#{file}'"}
    end
  end

  defp get_content(bash, _opts, stdin) do
    {:ok, stdin, bash}
  end

  defp render(content, opts) do
    mdex_opts = build_mdex_opts(opts)

    case MDEx.to_html(content, mdex_opts) do
      {:ok, html} -> {:ok, html}
      {:error, error} -> {:error, "parse error: #{inspect(error)}"}
    end
  end

  defp build_mdex_opts(opts) do
    [
      extension: [
        table: opts.gfm,
        strikethrough: opts.gfm,
        autolink: opts.gfm,
        tasklist: opts.gfm,
        tagfilter: opts.gfm
      ],
      parse: [smart: opts.smartypants],
      render: [hardbreaks: opts.breaks]
    ]
  end

  defp parse_args(args) do
    {option_args, extra} = StdinOperand.split_end_of_options(args)

    with {:ok, opts} <-
           parse_args(option_args, %{
             file: nil,
             gfm: true,
             breaks: false,
             smartypants: false,
             help: false
           }) do
      case {opts.file, extra} do
        {_file, []} -> {:ok, opts}
        {nil, [file | _]} -> {:ok, %{opts | file: file}}
        {_file, _} -> {:ok, opts}
      end
    end
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["--help" | _], opts), do: {:ok, %{opts | help: true}}
  defp parse_args(["-h" | _], opts), do: {:ok, %{opts | help: true}}

  defp parse_args(["--smartypants" | rest], opts) do
    parse_args(rest, %{opts | smartypants: true})
  end

  defp parse_args(["--gfm" | rest], opts) do
    parse_args(rest, %{opts | gfm: true})
  end

  defp parse_args(["--no-gfm" | rest], opts) do
    parse_args(rest, %{opts | gfm: false})
  end

  defp parse_args(["--breaks" | rest], opts) do
    parse_args(rest, %{opts | breaks: true})
  end

  defp parse_args([arg | rest], %{file: nil} = opts) do
    parse_args(rest, %{opts | file: arg})
  end

  defp parse_args([_ | rest], opts) do
    parse_args(rest, opts)
  end
end
