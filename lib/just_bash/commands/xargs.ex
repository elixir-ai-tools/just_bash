defmodule JustBash.Commands.Xargs do
  @moduledoc "The `xargs` command - build and execute command lines from standard input."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["xargs"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        if Map.has_key?(opts, :help) do
          {Command.ok(opts.help), bash}
        else
          items = parse_input(stdin, opts)

          if items == [] do
            if opts.no_run_if_empty do
              {Command.ok(""), bash}
            else
              {Command.ok(""), bash}
            end
          else
            command = if opts.command == [], do: ["echo"], else: opts.command
            execute_commands(bash, items, command, opts)
          end
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{
      replace_str: nil,
      max_args: nil,
      max_procs: nil,
      null_separator: false,
      verbose: false,
      no_run_if_empty: false,
      command: []
    })
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["--help" | _rest], opts) do
    help = """
    xargs - build and execute command lines from standard input

    Usage: xargs [OPTION]... [COMMAND [INITIAL-ARGS]]

    Options:
      -I REPLACE   replace occurrences of REPLACE with input
      -n NUM       use at most NUM arguments per command line
      -P NUM       run at most NUM processes at a time
      -0, --null   items are separated by null, not whitespace
      -t, --verbose  print commands before executing
      -r, --no-run-if-empty  do not run command if input is empty
          --help   display this help and exit
    """

    {:ok, Map.put(opts, :help, help)}
  end

  defp parse_args(["-I", replace_str | rest], opts) do
    parse_args(rest, %{opts | replace_str: replace_str})
  end

  defp parse_args(["-n", num_str | rest], opts) do
    case Integer.parse(num_str) do
      {n, ""} when n > 0 -> parse_args(rest, %{opts | max_args: n})
      _ -> {:error, "xargs: invalid number for -n: '#{num_str}'\n"}
    end
  end

  defp parse_args(["-P", num_str | rest], opts) do
    case Integer.parse(num_str) do
      {n, ""} when n >= 0 -> parse_args(rest, %{opts | max_procs: n})
      _ -> {:error, "xargs: invalid number for -P: '#{num_str}'\n"}
    end
  end

  defp parse_args(["-0" | rest], opts) do
    parse_args(rest, %{opts | null_separator: true})
  end

  defp parse_args(["--null" | rest], opts) do
    parse_args(rest, %{opts | null_separator: true})
  end

  defp parse_args(["-t" | rest], opts) do
    parse_args(rest, %{opts | verbose: true})
  end

  defp parse_args(["--verbose" | rest], opts) do
    parse_args(rest, %{opts | verbose: true})
  end

  defp parse_args(["-r" | rest], opts) do
    parse_args(rest, %{opts | no_run_if_empty: true})
  end

  defp parse_args(["--no-run-if-empty" | rest], opts) do
    parse_args(rest, %{opts | no_run_if_empty: true})
  end

  defp parse_args(["-" <> flags | rest], opts) when byte_size(flags) > 0 do
    chars = String.graphemes(flags)

    if Enum.all?(chars, &(&1 in ["0", "t", "r"])) do
      new_opts =
        Enum.reduce(chars, opts, fn char, acc ->
          case char do
            "0" -> %{acc | null_separator: true}
            "t" -> %{acc | verbose: true}
            "r" -> %{acc | no_run_if_empty: true}
          end
        end)

      parse_args(rest, new_opts)
    else
      unknown = Enum.find(chars, &(&1 not in ["0", "t", "r"]))
      {:error, "xargs: invalid option -- '#{unknown}'\n"}
    end
  end

  defp parse_args(["--" <> _ = arg | _rest], _opts) do
    {:error, "xargs: unrecognized option '#{arg}'\n"}
  end

  defp parse_args([cmd | rest], opts) do
    {:ok, %{opts | command: [cmd | rest]}}
  end

  defp parse_input(stdin, opts) do
    cond do
      opts.null_separator ->
        stdin
        |> String.split("\0")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))

      opts.replace_str != nil ->
        stdin
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))

      true ->
        stdin
        |> String.split(~r/\s+/)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))
    end
  end

  defp execute_commands(bash, items, command, opts) do
    cond do
      opts.replace_str != nil ->
        execute_with_replacement(bash, items, command, opts)

      opts.max_args != nil ->
        execute_with_batching(bash, items, command, opts)

      true ->
        execute_all_at_once(bash, items, command, opts)
    end
  end

  defp execute_with_replacement(bash, items, command, opts) do
    {final_bash, stdout, stderr, exit_code} =
      Enum.reduce(items, {bash, "", "", 0}, fn item, {b, out, err, code} ->
        cmd_args = Enum.map(command, &String.replace(&1, opts.replace_str, item))
        cmd_line = Enum.join(cmd_args, " ")

        new_err = if opts.verbose, do: err <> "#{cmd_line}\n", else: err

        {result, new_bash} = JustBash.exec(b, cmd_line)

        new_code = if result.exit_code != 0, do: result.exit_code, else: code
        {new_bash, out <> result.stdout, new_err <> result.stderr, new_code}
      end)

    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, final_bash}
  end

  defp execute_with_batching(bash, items, command, opts) do
    batches = Enum.chunk_every(items, opts.max_args)

    {final_bash, stdout, stderr, exit_code} =
      Enum.reduce(batches, {bash, "", "", 0}, fn batch, {b, out, err, code} ->
        cmd_args = command ++ batch
        cmd_line = Enum.join(cmd_args, " ")

        new_err = if opts.verbose, do: err <> "#{cmd_line}\n", else: err

        {result, new_bash} = JustBash.exec(b, cmd_line)

        new_code = if result.exit_code != 0, do: result.exit_code, else: code
        {new_bash, out <> result.stdout, new_err <> result.stderr, new_code}
      end)

    {%{stdout: stdout, stderr: stderr, exit_code: exit_code}, final_bash}
  end

  defp execute_all_at_once(bash, items, command, opts) do
    cmd_args = command ++ items
    cmd_line = Enum.join(cmd_args, " ")

    stderr = if opts.verbose, do: "#{cmd_line}\n", else: ""

    {result, new_bash} = JustBash.exec(bash, cmd_line)

    {%{stdout: result.stdout, stderr: stderr <> result.stderr, exit_code: result.exit_code},
     new_bash}
  end
end
