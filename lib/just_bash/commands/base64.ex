defmodule JustBash.Commands.Base64 do
  @moduledoc "The `base64` command - base64 encode/decode data."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["base64"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        content =
          if opts.files == [] or opts.files == ["-"] do
            stdin
          else
            case read_files(bash, opts.files) do
              {:ok, data} -> data
              {:error, msg} -> {:error, msg}
            end
          end

        case content do
          {:error, msg} ->
            {Command.error(msg), bash}

          data ->
            result =
              if opts.decode do
                decode_base64(data)
              else
                encode_base64(data, opts.wrap)
              end

            case result do
              {:ok, output} -> {Command.ok(output), bash}
              {:error, msg} -> {Command.error(msg), bash}
            end
        end
    end
  end

  defp parse_args(args) do
    parse_args(args, %{decode: false, wrap: 76, files: []})
  end

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["-d" | rest], opts) do
    parse_args(rest, %{opts | decode: true})
  end

  defp parse_args(["--decode" | rest], opts) do
    parse_args(rest, %{opts | decode: true})
  end

  defp parse_args(["-w", cols | rest], opts) do
    case Integer.parse(cols) do
      {c, ""} when c >= 0 -> parse_args(rest, %{opts | wrap: c})
      _ -> {:error, "base64: invalid wrap size: '#{cols}'\n"}
    end
  end

  defp parse_args(["--wrap=" <> cols | rest], opts) do
    case Integer.parse(cols) do
      {c, ""} when c >= 0 -> parse_args(rest, %{opts | wrap: c})
      _ -> {:error, "base64: invalid wrap size: '#{cols}'\n"}
    end
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "base64: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp read_files(bash, files) do
    Enum.reduce_while(files, {:ok, ""}, fn file, {:ok, acc} ->
      if file == "-" do
        {:cont, {:ok, acc}}
      else
        resolved = InMemoryFs.resolve_path(bash.cwd, file)

        case InMemoryFs.read_file(bash.fs, resolved) do
          {:ok, data} -> {:cont, {:ok, acc <> data}}
          {:error, _} -> {:halt, {:error, "base64: #{file}: No such file or directory\n"}}
        end
      end
    end)
  end

  defp encode_base64(data, wrap) do
    encoded = Base.encode64(data)

    output =
      if wrap > 0 do
        encoded
        |> String.graphemes()
        |> Enum.chunk_every(wrap)
        |> Enum.map(&Enum.join/1)
        |> Enum.join("\n")
        |> then(fn s -> if s == "", do: "", else: s <> "\n" end)
      else
        encoded
      end

    {:ok, output}
  end

  defp decode_base64(data) do
    cleaned = String.replace(data, ~r/\s/, "")

    case Base.decode64(cleaned) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "base64: invalid input\n"}
    end
  end
end
