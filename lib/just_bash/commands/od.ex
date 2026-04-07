defmodule JustBash.Commands.Od do
  @moduledoc "The `od` command - dump files in octal and other formats."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["od"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args, %{format: :octal, file: nil}) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        case read_input(bash, opts.file, stdin) do
          {:ok, data} -> {Command.ok(render(data, opts.format)), bash}
          {:error, msg} -> {Command.error(msg), bash}
        end
    end
  end

  defp parse_args([], opts), do: {:ok, opts}
  defp parse_args(["-c" | rest], opts), do: parse_args(rest, %{opts | format: :char})
  defp parse_args(["-b" | rest], opts), do: parse_args(rest, %{opts | format: :octal_bytes})
  defp parse_args(["-x" | rest], opts), do: parse_args(rest, %{opts | format: :hex})
  defp parse_args(["-An" | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["-A", _ | rest], opts), do: parse_args(rest, opts)
  defp parse_args(["-t", _ | rest], opts), do: parse_args(rest, opts)

  defp parse_args(["-" <> _ = flag | _], _opts),
    do: {:error, "od: unknown option: #{flag}\n"}

  defp parse_args([file | rest], opts), do: parse_args(rest, %{opts | file: file})

  defp read_input(_bash, nil, stdin), do: {:ok, stdin || ""}
  defp read_input(_bash, "-", stdin), do: {:ok, stdin || ""}

  defp read_input(bash, file, _stdin) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, c} -> {:ok, c}
      {:error, _} -> {:error, "od: #{file}: No such file or directory\n"}
    end
  end

  defp render(data, format) do
    bytes = :binary.bin_to_list(data)

    lines =
      bytes
      |> Enum.chunk_every(16)
      |> Enum.with_index()
      |> Enum.map(fn {chunk, idx} -> format_line(chunk, idx * 16, format) end)

    final_offset = byte_size(data) |> Integer.to_string(8) |> String.pad_leading(7, "0")
    Enum.join(lines ++ [final_offset <> "\n"])
  end

  defp format_line(chunk, offset, format) do
    off = offset |> Integer.to_string(8) |> String.pad_leading(7, "0")
    cells = Enum.map_join(chunk, " ", &format_byte(&1, format))
    "#{off} #{cells}\n"
  end

  defp format_byte(b, :char), do: char_repr(b)

  defp format_byte(b, :octal_bytes),
    do: b |> Integer.to_string(8) |> String.pad_leading(3, "0")

  defp format_byte(b, :hex),
    do: b |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  defp format_byte(b, :octal),
    do: b |> Integer.to_string(8) |> String.pad_leading(3, "0")

  defp char_repr(0), do: "\\0"
  defp char_repr(7), do: "\\a"
  defp char_repr(8), do: "\\b"
  defp char_repr(9), do: "\\t"
  defp char_repr(10), do: "\\n"
  defp char_repr(11), do: "\\v"
  defp char_repr(12), do: "\\f"
  defp char_repr(13), do: "\\r"
  defp char_repr(b) when b >= 32 and b <= 126, do: "  " <> <<b>>
  defp char_repr(b), do: b |> Integer.to_string(8) |> String.pad_leading(3, "0")
end
