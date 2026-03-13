defmodule JustBash.Commands.Mktemp do
  @moduledoc """
  The `mktemp` command - create a temporary file or directory.

  Creates uniquely-named temporary files or directories in the virtual filesystem.

  Supports:
  - `mktemp` — create a temp file in /tmp
  - `mktemp -d` — create a temp directory
  - `mktemp TEMPLATE` — template with trailing X's replaced by random chars
  - `mktemp -t prefix` — create in /tmp with given prefix
  - `mktemp -p DIR` / `--tmpdir=DIR` — use DIR instead of /tmp
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["mktemp"]

  @impl true
  def execute(bash, args, _stdin) do
    {opts, positional} = parse_args(args)
    template = List.first(positional)

    tmpdir = opts.tmpdir || Map.get(bash.env, "TMPDIR", "/tmp")

    {name, is_template} =
      case template do
        nil ->
          {"tmp.XXXXXXXXXX", false}

        tpl ->
          {tpl, true}
      end

    # If -t flag is given, the positional is a prefix, not a template
    {name, is_template} =
      if opts.use_tmpdir and not is_template do
        {name, false}
      else
        if opts.use_tmpdir do
          {"#{name}.XXXXXXXXXX", false}
        else
          {name, is_template}
        end
      end

    # Generate the random part
    generated = expand_template(name)

    # Determine full path
    path =
      if is_template and String.contains?(name, "/") do
        generated
      else
        Path.join(tmpdir, generated)
      end

    resolved = InMemoryFs.resolve_path(bash.cwd, path)

    if opts.directory do
      case InMemoryFs.mkdir(bash.fs, resolved, recursive: true) do
        {:ok, new_fs} ->
          {Command.ok(path <> "\n"), %{bash | fs: new_fs}}

        {:error, reason} ->
          {Command.error("mktemp: failed to create directory: #{reason}\n"), bash}
      end
    else
      case InMemoryFs.write_file(bash.fs, resolved, "") do
        {:ok, new_fs} ->
          {Command.ok(path <> "\n"), %{bash | fs: new_fs}}

        {:error, reason} ->
          {Command.error("mktemp: failed to create file: #{reason}\n"), bash}
      end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{directory: false, use_tmpdir: false, tmpdir: nil}, [])
  end

  defp parse_args([], opts, pos), do: {opts, Enum.reverse(pos)}

  defp parse_args(["-d" | rest], opts, pos),
    do: parse_args(rest, %{opts | directory: true}, pos)

  defp parse_args(["-t" | rest], opts, pos),
    do: parse_args(rest, %{opts | use_tmpdir: true}, pos)

  defp parse_args(["-p", dir | rest], opts, pos),
    do: parse_args(rest, %{opts | tmpdir: dir}, pos)

  defp parse_args(["--tmpdir=" <> dir | rest], opts, pos),
    do: parse_args(rest, %{opts | tmpdir: dir}, pos)

  defp parse_args(["-" <> _ | rest], opts, pos),
    do: parse_args(rest, opts, pos)

  defp parse_args([arg | rest], opts, pos),
    do: parse_args(rest, opts, [arg | pos])

  defp expand_template(template) do
    # Replace trailing X's with random alphanumeric characters
    case Regex.run(~r/(X+)$/, template) do
      [match | _] ->
        random = random_string(String.length(match))
        String.replace_suffix(template, match, random)

      nil ->
        template <> "." <> random_string(10)
    end
  end

  defp random_string(length) do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    1..length
    |> Enum.map(fn _ -> Enum.random(alphabet) end)
    |> List.to_string()
  end
end
