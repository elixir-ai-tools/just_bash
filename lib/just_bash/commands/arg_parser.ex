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
  - `:float` - Takes a floating-point value
  - `:accumulator` - Accumulates multiple values into a list (for -H headers, etc.)

  ## Options

  - `:short` - Short flag form (e.g., "-s")
  - `:long` - Long flag form (e.g., "--silent")
  - `:type` - Value type (`:boolean`, `:string`, `:integer`, `:float`, `:accumulator`)
  - `:default` - Default value if flag not provided
  - `:required` - When `true`, parsing fails if the flag is not provided
  - `:values` - List of allowed values; parsing fails on anything else (enum)
  - `:transform` - Optional function to transform the value
  """

  @type flag_type :: :boolean | :string | :integer | :float | :accumulator
  @type flag_spec :: [
          short: String.t(),
          long: String.t(),
          type: flag_type(),
          default: any(),
          required: boolean(),
          values: [any()],
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

    # Parse into a map of only the flags that were actually provided, so we can
    # distinguish "set" from "defaulted" for required-flag checking. Defaults are
    # merged in afterwards.
    with {:ok, provided, positional} <- parse_loop(args, ctx, %{}, []),
         :ok <- check_required(flags, provided, ctx.command) do
      {:ok, merge_defaults(flags, provided), positional}
    end
  end

  defp build_flag_maps(flags) do
    Enum.reduce(flags, {%{}, %{}}, fn {name, spec}, {shorts, longs} ->
      shorts = if spec[:short], do: Map.put(shorts, spec[:short], {name, spec}), else: shorts
      longs = if spec[:long], do: Map.put(longs, spec[:long], {name, spec}), else: longs
      {shorts, longs}
    end)
  end

  # Fill in defaults for any flag that was not provided on the command line.
  defp merge_defaults(flags, provided) do
    Enum.reduce(flags, provided, fn {name, spec}, acc ->
      if Map.has_key?(acc, name) do
        acc
      else
        Map.put(acc, name, default_for(spec))
      end
    end)
  end

  defp default_for(spec) do
    case spec[:type] do
      :boolean -> Keyword.get(spec, :default, false)
      :accumulator -> Keyword.get(spec, :default, [])
      _ -> Keyword.get(spec, :default)
    end
  end

  # Fail if any flag marked `required: true` was not provided.
  defp check_required(flags, provided, command) do
    Enum.reduce_while(flags, :ok, fn {name, spec}, :ok ->
      if spec[:required] && not Map.has_key?(provided, name) do
        {:halt, {:error, format_required_error(command, spec)}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp flag_display_name(spec), do: spec[:long] || spec[:short]

  defp format_required_error("", spec),
    do: "missing required flag: #{flag_display_name(spec)}\n"

  defp format_required_error(cmd, spec),
    do: "#{cmd}: missing required flag: #{flag_display_name(spec)}\n"

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
    with nil <- Map.get(ctx.short_map, flag),
         nil <- Map.get(ctx.long_map, flag) do
      handle_unknown_short_flag(flag, args, ctx, opts, positional)
    else
      {name, spec} -> handle_flag(name, spec, args, ctx, opts, positional)
    end
  end

  defp handle_unknown_short_flag(flag, args, ctx, opts, positional) do
    case expand_combined_flags(flag, ctx) do
      {:ok, expanded} ->
        parse_loop(expanded ++ args, ctx, opts, positional)

      :error ->
        if ctx.allow_unknown,
          do: parse_loop(args, ctx, opts, [flag | positional]),
          else: {:error, format_unknown_error(ctx.command, flag)}
    end
  end

  # Expand combined short flags like -fsSL into [-f, -s, -S, -L].
  # Only succeeds if ALL letters map to known boolean short flags.
  defp expand_combined_flags("-" <> chars, ctx) when byte_size(chars) > 1 do
    flags =
      chars
      |> String.graphemes()
      |> Enum.map(fn c -> "-" <> c end)

    all_boolean? =
      Enum.all?(flags, fn f ->
        case Map.get(ctx.short_map, f) do
          {_name, spec} -> spec[:type] == :boolean
          nil -> false
        end
      end)

    if all_boolean?, do: {:ok, flags}, else: :error
  end

  defp expand_combined_flags(_, _ctx), do: :error

  defp handle_flag(name, spec, args, ctx, opts, positional) do
    case spec[:type] do
      :boolean ->
        new_opts = Map.put(opts, name, true)
        parse_loop(args, ctx, new_opts, positional)

      type when type in [:string, :integer, :float, :accumulator] ->
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
    with {:ok, typed} <- coerce_value(spec[:type], value),
         transformed = apply_transform(spec, typed),
         :ok <- check_enum(spec, transformed) do
      {:ok, store_value(opts, name, spec, transformed)}
    end
  end

  defp coerce_value(:string, value), do: {:ok, value}
  defp coerce_value(:accumulator, value), do: {:ok, value}

  defp coerce_value(:boolean, value), do: {:ok, value in ["true", "1", "yes"]}

  # Strict: the whole value must be the number, so a typo like "42x" or a
  # thousands-separated "1_000" is a loud error rather than a silent truncation to 42/1.
  defp coerce_value(:integer, value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "invalid integer value: #{value}\n"}
    end
  end

  defp coerce_value(:float, value) do
    case Float.parse(value) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "invalid float value: #{value}\n"}
    end
  end

  # Accumulators append to a list; every other type overwrites.
  defp store_value(opts, name, spec, value) do
    case spec[:type] do
      :accumulator ->
        current = Map.get(opts, name, [])
        Map.put(opts, name, current ++ [value])

      _ ->
        Map.put(opts, name, value)
    end
  end

  defp check_enum(spec, value) do
    case spec[:values] do
      nil ->
        :ok

      values ->
        if value in values do
          :ok
        else
          {:error,
           "invalid value for #{flag_display_name(spec)}: #{value} (allowed: #{Enum.join(values, ", ")})\n"}
        end
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
