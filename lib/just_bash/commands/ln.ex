defmodule JustBash.Commands.Ln do
  @moduledoc "The `ln` command - make links between files."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["ln"]

  @impl true
  def execute(bash, args, _stdin) do
    {:ok, opts} = parse_args(args)

    if opts.files == [] or length(opts.files) < 2 do
      {Command.error("ln: missing file operand\n"), bash}
    else
      [target | rest] = opts.files
      link_name = List.last(rest)
      link_path = InMemoryFs.resolve_path(bash.cwd, link_name)

      case create_link(bash, target, link_path, link_name, opts) do
        {:ok, new_bash, output} ->
          {Command.ok(output), new_bash}

        {:error, msg} ->
          {Command.error(msg), bash}
      end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{symbolic: false, force: false, verbose: false, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-s" | rest], opts) do
    parse_args(rest, %{opts | symbolic: true})
  end

  defp parse_args(["--symbolic" | rest], opts) do
    parse_args(rest, %{opts | symbolic: true})
  end

  defp parse_args(["-f" | rest], opts) do
    parse_args(rest, %{opts | force: true})
  end

  defp parse_args(["--force" | rest], opts) do
    parse_args(rest, %{opts | force: true})
  end

  defp parse_args(["-v" | rest], opts) do
    parse_args(rest, %{opts | verbose: true})
  end

  defp parse_args(["--verbose" | rest], opts) do
    parse_args(rest, %{opts | verbose: true})
  end

  defp parse_args(["-n" | rest], opts) do
    parse_args(rest, opts)
  end

  defp parse_args(["--no-dereference" | rest], opts) do
    parse_args(rest, opts)
  end

  defp parse_args(["-sf" | rest], opts) do
    parse_args(rest, %{opts | symbolic: true, force: true})
  end

  defp parse_args(["-fs" | rest], opts) do
    parse_args(rest, %{opts | symbolic: true, force: true})
  end

  defp parse_args(["-sfv" | rest], opts) do
    parse_args(rest, %{opts | symbolic: true, force: true, verbose: true})
  end

  defp parse_args(["--" | rest], opts) do
    {:ok, %{opts | files: opts.files ++ rest}}
  end

  defp parse_args(["-" <> flags | rest], opts) when byte_size(flags) > 0 do
    new_opts =
      flags
      |> String.graphemes()
      |> Enum.reduce(opts, fn char, acc ->
        case char do
          "s" -> %{acc | symbolic: true}
          "f" -> %{acc | force: true}
          "v" -> %{acc | verbose: true}
          "n" -> acc
          _ -> acc
        end
      end)

    parse_args(rest, new_opts)
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp create_link(bash, target, link_path, link_name, opts) do
    fs = bash.fs

    fs =
      if opts.force do
        case InMemoryFs.rm(fs, link_path) do
          {:ok, new_fs} -> new_fs
          {:error, _} -> fs
        end
      else
        fs
      end

    result =
      if opts.symbolic do
        InMemoryFs.symlink(fs, target, link_path)
      else
        target_path = InMemoryFs.resolve_path(bash.cwd, target)

        case InMemoryFs.stat(fs, target_path) do
          {:ok, %{is_file: true}} ->
            InMemoryFs.link(fs, target_path, link_path)

          {:ok, %{is_directory: true}} ->
            {:error, :eperm}

          {:error, _} ->
            {:error, :enoent}
        end
      end

    case result do
      {:ok, new_fs} ->
        output = if opts.verbose, do: "'#{link_name}' -> '#{target}'\n", else: ""
        {:ok, %{bash | fs: new_fs}, output}

      {:error, :eexist} ->
        link_type = if opts.symbolic, do: "symbolic ", else: ""
        {:error, "ln: failed to create #{link_type}link '#{link_name}': File exists\n"}

      {:error, :enoent} ->
        {:error, "ln: failed to access '#{target}': No such file or directory\n"}

      {:error, :eperm} ->
        {:error, "ln: '#{target}': hard link not allowed for directory\n"}
    end
  end
end
