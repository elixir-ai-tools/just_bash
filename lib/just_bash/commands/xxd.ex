defmodule JustBash.Commands.Xxd do
  @moduledoc "The `xxd` command - make a hexdump."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["xxd"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args, %{cols: 16, len: nil, seek: 0, plain: false, file: nil}) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        case read_input(bash, opts.file, stdin) do
          {:ok, data} ->
            data = slice(data, opts.seek, opts.len)
            out = if opts.plain, do: plain(data), else: dump(data, opts.cols)
            {Command.ok(out), bash}

          {:error, msg} ->
            {Command.error(msg), bash}
        end
    end
  end

  defp parse_args([], opts), do: {:ok, opts}
  defp parse_args(["-c", n | rest], opts), do: parse_args(rest, %{opts | cols: to_int(n)})
  defp parse_args(["-l", n | rest], opts), do: parse_args(rest, %{opts | len: to_int(n)})
  defp parse_args(["-s", n | rest], opts), do: parse_args(rest, %{opts | seek: to_int(n)})
  defp parse_args(["-p" | rest], opts), do: parse_args(rest, %{opts | plain: true})
  defp parse_args(["-r" | _], _opts), do: {:error, "xxd: -r not supported\n"}

  defp parse_args(["-" <> _ = flag | _], _opts),
    do: {:error, "xxd: unknown option: #{flag}\n"}

  defp parse_args([file | rest], opts), do: parse_args(rest, %{opts | file: file})

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> 0
    end
  end

  defp read_input(_bash, nil, stdin), do: {:ok, stdin || ""}
  defp read_input(_bash, "-", stdin), do: {:ok, stdin || ""}

  defp read_input(bash, file, _stdin) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, c} -> {:ok, c}
      {:error, _} -> {:error, "xxd: #{file}: No such file or directory\n"}
    end
  end

  defp slice(data, 0, nil), do: data
  defp slice(data, seek, nil), do: binary_part_safe(data, seek, byte_size(data) - seek)

  defp slice(data, seek, len) do
    max = max(byte_size(data) - seek, 0)
    binary_part_safe(data, seek, min(len, max))
  end

  defp binary_part_safe(_data, _start, len) when len <= 0, do: ""
  defp binary_part_safe(data, start, len), do: binary_part(data, start, len)

  defp plain(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.chunk_every(30)
    |> Enum.map_join("\n", &Enum.join/1)
    |> then(&(&1 <> "\n"))
  end

  defp dump(data, cols) do
    data
    |> :binary.bin_to_list()
    |> Enum.chunk_every(cols)
    |> Enum.with_index()
    |> Enum.map_join(fn {bytes, idx} -> format_line(bytes, idx * cols, cols) end)
  end

  defp format_line(bytes, offset, cols) do
    offset_str =
      offset |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")

    hex =
      bytes
      |> Enum.chunk_every(2)
      |> Enum.map_join(" ", fn pair ->
        Enum.map_join(pair, "", fn b ->
          b |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
        end)
      end)

    hex_width = div(cols, 2) * 5 - 1
    hex_padded = String.pad_trailing(hex, hex_width)

    ascii =
      Enum.map_join(bytes, "", fn b -> if b >= 32 and b <= 126, do: <<b>>, else: "." end)

    "#{offset_str}: #{hex_padded}  #{ascii}\n"
  end
end
