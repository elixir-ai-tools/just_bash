defmodule JustBash.Commands.Base64 do
  @moduledoc "The `base64` command - base64 encode/decode data."
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Commands.StdinOperand
  alias JustBash.FS

  @impl true
  def names, do: ["base64"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        {content, bash} = get_content(opts, bash, stdin)

        content
        |> process_content(opts)
        |> build_result(bash)
    end
  end

  defp get_content(%{files: []}, bash, stdin), do: {{:ok, stdin}, bash}
  defp get_content(opts, bash, stdin), do: read_files(bash, opts.files, stdin)

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
    {option_args, extra} = StdinOperand.split_end_of_options(args)

    with {:ok, opts} <- parse_args(option_args, %{decode: false, wrap: 76, files: []}) do
      {:ok, %{opts | files: opts.files ++ extra}}
    end
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

  # A bare `-` is never a flag: POSIX reads it as the stdin operand.
  defp parse_args(["-" | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ ["-"]})
  end

  defp parse_args(["-" <> _ = arg | _rest], _opts) do
    {:error, "base64: invalid option '#{arg}'\n"}
  end

  defp parse_args([file | rest], opts) do
    parse_args(rest, %{opts | files: opts.files ++ [file]})
  end

  defp read_files(bash, files, stdin) do
    result =
      Enum.reduce_while(files, {:ok, "", bash.fs}, fn file, {:ok, acc, fs} ->
        read_single_file(bash, fs, file, stdin, acc)
      end)

    case result do
      {:ok, acc, fs} -> {{:ok, acc}, %{bash | fs: fs}}
      {:error, _} = err -> {err, bash}
    end
  end

  defp read_single_file(bash, fs, file, stdin, acc) do
    case StdinOperand.read(fs, bash.cwd, file, stdin) do
      {:ok, data, fs} -> {:cont, {:ok, acc <> data, fs}}
      {:error, error} -> {:halt, {:error, "base64: #{file}: #{FS.strerror(error)}\n"}}
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
