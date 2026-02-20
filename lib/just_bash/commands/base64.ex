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
        opts
        |> get_content(bash, stdin)
        |> process_content(opts)
        |> build_result(bash)
    end
  end

  defp get_content(opts, bash, stdin) do
    if opts.files == [] or opts.files == ["-"] do
      {:ok, stdin}
    else
      read_files(bash, opts.files)
    end
  end

  defp process_content({:error, msg}, _opts), do: {:error, msg}

  defp process_content({:ok, data}, opts) do
    if opts.decode do
      decode_base64(data)
    else
      encode_base64(data, opts.wrap)
    end
  end

  defp build_result({:ok, output}, bash), do: {Command.ok(output), bash}
  defp build_result({:error, msg}, bash), do: {Command.error(msg), bash}

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
      read_single_file(bash, file, acc)
    end)
  end

  defp read_single_file(_bash, "-", acc), do: {:cont, {:ok, acc}}

  defp read_single_file(bash, file, acc) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash, resolved) do
      {:ok, data, _new_bash} -> {:cont, {:ok, acc <> data}}
      {:error, _} -> {:halt, {:error, "base64: #{file}: No such file or directory\n"}}
    end
  end

  defp encode_base64(data, wrap) do
    encoded = Base.encode64(data)
    output = wrap_encoded(encoded, wrap)
    {:ok, output}
  end

  defp wrap_encoded(encoded, 0), do: encoded

  defp wrap_encoded(encoded, wrap) do
    encoded
    |> String.graphemes()
    |> Enum.chunk_every(wrap)
    |> Enum.map_join("\n", &Enum.join/1)
    |> add_trailing_newline()
  end

  defp add_trailing_newline(""), do: ""
  defp add_trailing_newline(s), do: s <> "\n"

  defp decode_base64(data) do
    cleaned = String.replace(data, ~r/\s/, "")

    case Base.decode64(cleaned) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "base64: invalid input\n"}
    end
  end
end
