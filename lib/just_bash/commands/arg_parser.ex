defmodule JustBash.Commands.ArgParser do
  @moduledoc """
  Declarative command-line argument parser for shell commands.

  Provides a simple DSL for defining command flags and their behaviors,
  eliminating repetitive manual parsing code.

  ## Usage

      @flags [
        silent: [short: "-s", long: "--silent", type: :boolean],
        output: [short: "-o", long: "--output", type: :string],
        count: [short: "-n", type: :integer, default: 1],
        method: [short: "-X", long: "--request", type: :string, default: "GET"]
      ]

      case ArgParser.parse(args, @flags) do
        {:ok, opts, positional} ->
          # opts is a map like %{silent: true, output: "file.txt", count: 1}
          # positional is remaining non-flag arguments
        {:error, message} ->
          # e.g., "unknown option: --foo"
      end

  ## Flag Types

  - `:boolean` - Flag is present or absent (no value needed)
  - `:string` - Takes a string value
  - `:integer` - Takes an integer value
  - `:accumulator` - Accumulates multiple values into a list (for -H headers, etc.)

  ## Options

  - `:short` - Short flag form (e.g., "-s")
  - `:long` - Long flag form (e.g., "--silent")  
  - `:type` - Value type (`:boolean`, `:string`, `:integer`, `:accumulator`)
  - `:default` - Default value if flag not provided
  - `:transform` - Optional function to transform the value
  """

  @type flag_type :: :boolean | :string | :integer | :accumulator
  @type flag_spec :: [
          short: String.t(),
          long: String.t(),
          type: flag_type(),
          default: any(),
          transform: (String.t() -> any())
        ]
  @type flags_spec :: [{atom(), flag_spec()}]

  # Parser context struct to reduce function arity
  defmodule Context do
    @moduledoc false
    defstruct [:short_map, :long_map, :command, :allow_unknown]
  end

  @doc """
  Parse command-line arguments according to the flag specification.

  Returns `{:ok, opts_map, positional_args}` or `{:error, message}`.
  """
  @spec parse([String.t()], flags_spec(), keyword()) ::
          {:ok, map(), [String.t()]} | {:error, String.t()}
  def parse(args, flags, opts \\ []) do
    # Build lookup maps for efficient flag matching
    {short_map, long_map} = build_flag_maps(flags)

    ctx = %Context{
      short_map: short_map,
      long_map: long_map,
      command: Keyword.get(opts, :command, ""),
      allow_unknown: Keyword.get(opts, :allow_unknown, false)
    }

    # Build defaults and parse arguments
    defaults = build_defaults(flags)
    parse_loop(args, ctx, defaults, [])
  end

  defp build_flag_maps(flags) do
    Enum.reduce(flags, {%{}, %{}}, fn {name, spec}, {shorts, longs} ->
      shorts = if spec[:short], do: Map.put(shorts, spec[:short], {name, spec}), else: shorts
      longs = if spec[:long], do: Map.put(longs, spec[:long], {name, spec}), else: longs
      {shorts, longs}
    end)
  end

  defp build_defaults(flags) do
    Enum.reduce(flags, %{}, fn {name, spec}, acc ->
      default =
        case spec[:type] do
          :boolean -> Keyword.get(spec, :default, false)
          :accumulator -> Keyword.get(spec, :default, [])
          _ -> Keyword.get(spec, :default)
        end

      Map.put(acc, name, default)
    end)
  end

  defp parse_loop([], _ctx, opts, positional) do
    {:ok, opts, Enum.reverse(positional)}
  end

  # Stop parsing flags after --
  defp parse_loop(["--" | rest], _ctx, opts, positional) do
    {:ok, opts, Enum.reverse(positional) ++ rest}
  end

  # Long flag with = value: --flag=value
  defp parse_loop([<<"--", rest::binary>> = arg | args], ctx, opts, positional) do
    case String.split(rest, "=", parts: 2) do
      [flag_name, value] ->
        long_flag = "--" <> flag_name

        case Map.get(ctx.long_map, long_flag) do
          {name, spec} ->
            case apply_value(opts, name, spec, value) do
              {:ok, new_opts} ->
                parse_loop(args, ctx, new_opts, positional)

              {:error, _} = err ->
                err
            end

          nil ->
            if ctx.allow_unknown do
              parse_loop(args, ctx, opts, [arg | positional])
            else
              {:error, format_unknown_error(ctx.command, arg)}
            end
        end

      [_flag_name] ->
        # No =, regular long flag
        parse_long_flag(arg, args, ctx, opts, positional)
    end
  end

  # Short flag
  defp parse_loop([<<"-", _::binary>> = arg | args], ctx, opts, positional) do
    parse_short_flag(arg, args, ctx, opts, positional)
  end

  # Positional argument
  defp parse_loop([arg | args], ctx, opts, positional) do
    parse_loop(args, ctx, opts, [arg | positional])
  end

  defp parse_long_flag(flag, args, ctx, opts, positional) do
    case Map.get(ctx.long_map, flag) do
      {name, spec} ->
        handle_flag(name, spec, args, ctx, opts, positional)

      nil ->
        if ctx.allow_unknown do
          parse_loop(args, ctx, opts, [flag | positional])
        else
          {:error, format_unknown_error(ctx.command, flag)}
        end
    end
  end

  defp parse_short_flag(flag, args, ctx, opts, positional) do
    case Map.get(ctx.short_map, flag) do
      {name, spec} ->
        handle_flag(name, spec, args, ctx, opts, positional)

      nil ->
        # Check if it's in long_map (some commands use -long-form)
        case Map.get(ctx.long_map, flag) do
          {name, spec} ->
            handle_flag(name, spec, args, ctx, opts, positional)

          nil ->
            if ctx.allow_unknown do
              parse_loop(args, ctx, opts, [flag | positional])
            else
              {:error, format_unknown_error(ctx.command, flag)}
            end
        end
    end
  end

  defp handle_flag(name, spec, args, ctx, opts, positional) do
    case spec[:type] do
      :boolean ->
        new_opts = Map.put(opts, name, true)
        parse_loop(args, ctx, new_opts, positional)

      type when type in [:string, :integer, :accumulator] ->
        case args do
          [value | rest] ->
            case apply_value(opts, name, spec, value) do
              {:ok, new_opts} ->
                parse_loop(rest, ctx, new_opts, positional)

              {:error, _} = err ->
                err
            end

          [] ->
            {:error, "#{ctx.command}: option requires an argument: #{name}\n"}
        end
    end
  end

  defp apply_value(opts, name, spec, value) do
    case spec[:type] do
      :string ->
        transformed = apply_transform(spec, value)
        {:ok, Map.put(opts, name, transformed)}

      :integer ->
        case Integer.parse(value) do
          {n, _} ->
            transformed = apply_transform(spec, n)
            {:ok, Map.put(opts, name, transformed)}

          :error ->
            {:error, "invalid integer value: #{value}\n"}
        end

      :accumulator ->
        transformed = apply_transform(spec, value)
        current = Map.get(opts, name, [])
        {:ok, Map.put(opts, name, current ++ [transformed])}

      :boolean ->
        # For boolean with explicit value
        bool_value = value in ["true", "1", "yes"]
        {:ok, Map.put(opts, name, bool_value)}
    end
  end

  defp apply_transform(spec, value) do
    case spec[:transform] do
      nil -> value
      fun when is_function(fun, 1) -> fun.(value)
    end
  end

  defp format_unknown_error("", flag), do: "unknown option: #{flag}\n"
  defp format_unknown_error(cmd, flag), do: "#{cmd}: unknown option: #{flag}\n"
end
