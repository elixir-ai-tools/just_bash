defmodule JustBash.Commands.Uniq do
  @moduledoc "The `uniq` command - report or omit repeated lines."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FlagParser
  alias JustBash.FS

  @flag_spec %{
    boolean: [:c, :d, :u],
    value: [],
    defaults: %{c: false, d: false, u: false},
    usage: "uniq [OPTION]... [INPUT [OUTPUT]]"
  }

  @usage "Try 'uniq --help' for more information.\n"

  @impl true
  def names, do: ["uniq"]

  @impl true
  def execute(bash, args, stdin) do
    case FlagParser.parse(args, @flag_spec) do
      {:ok, flags, files} -> uniq(bash, flags, files, stdin)
      :help -> {Command.ok(FlagParser.help("uniq", @flag_spec)), bash}
      {:error, reason} -> {Command.error(FlagParser.format_error("uniq", reason, @usage)), bash}
    end
  end

  defp uniq(bash, flags, files, stdin) do
    case get_content(bash, files, stdin) do
      {:error, message} -> {Command.error(message), bash}
      {:ok, content, fs} -> uniq_content(bash, content, flags, fs)
    end
  end

  defp get_content(bash, [], stdin), do: {:ok, stdin, bash.fs}

  defp get_content(bash, [file | _], stdin) do
    case StdinOperand.read(bash.fs, bash.cwd, file, stdin) do
      {:ok, content, fs} -> {:ok, content, fs}
      {:error, error} -> {:error, read_error(file, error)}
    end
  end

  # GNU uniq words the failure differently once the open has succeeded.
  defp read_error(file, %VFS.Error{kind: :eisdir} = error),
    do: "uniq: error reading '#{file}': #{FS.strerror(error)}\n"

  defp read_error(file, error), do: "uniq: #{file}: #{FS.strerror(error)}\n"

  defp uniq_content(bash, content, flags, fs) do
    lines = String.split(content, "\n", trim: true)

    output =
      cond do
        flags.c ->
          lines
          |> Enum.chunk_by(& &1)
          |> Enum.map_join("\n", fn chunk ->
            # GNU uniq pads count to 7 characters (right-aligned)
            count = String.pad_leading(Integer.to_string(length(chunk)), 7)
            "#{count} #{hd(chunk)}"
          end)

        flags.d and flags.u ->
          ""

        flags.d ->
          # Only print duplicate lines (lines that appear more than once)
          lines
          |> Enum.chunk_by(& &1)
          |> Enum.filter(fn chunk -> length(chunk) > 1 end)
          |> Enum.map_join("\n", &hd/1)

        flags.u ->
          # Only print unique lines (lines that appear exactly once)
          lines
          |> Enum.chunk_by(& &1)
          |> Enum.filter(fn chunk -> length(chunk) == 1 end)
          |> Enum.map_join("\n", &hd/1)

        true ->
          lines
          |> Enum.dedup()
          |> Enum.join("\n")
      end

    output = if output != "", do: output <> "\n", else: ""
    {Command.ok(output), %{bash | fs: fs}}
  end
end
