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
  - `:transform` - Optional function to transform the (coerced) value. It may return a
    bare value, `{:ok, value}`, or `{:error, message}`; the error channel fails parsing
    with that message, giving single-field validation (e.g. a numeric range) the same
    failure shape as a type or enum error.
  """

  @type flag_type :: :boolean | :string | :integer | :float | :accumulator
  @type transform :: (term() -> term() | {:ok, term()} | {:error, String.t()})
  @type flag_spec :: [
          short: String.t(),
          long: String.t(),
          type: flag_type(),
          default: any(),
          required: boolean(),
          values: [any()],
          transform: transform()
        ]
  @type flags_spec :: [{atom(), flag_spec()}]

  # Parser context struct to reduce function arity
  defmodule Context do
    @moduledoc false
    defstruct [:short_map, :long_map, :command, :allow_unknown, :collect_unknown]
  end

  @doc """
  Parse command-line arguments according to the flag specification.

  Returns `{:ok, opts_map, positional_args}` or `{:error, message}`.

  ## Options

    * `:command` — name included in error messages (e.g. `"acme pr review"`)
    * `:allow_unknown` — when `true`, an unrecognized flag is treated as a positional
      argument instead of an error
    * `:collect_unknown` — when `true`, unrecognized flags (and, for the bare `--flag value`
      form, a following non-flag token taken as the flag's value) are collected into a
      separate ordered list and the call returns a **4-tuple**
      `{:ok, opts, positional, extra}`. Positionals stay out of `extra`, so a host can
      forward the raw `extra` tokens to a backend whose flags aren't known at definition
      time. `--flag=value` is forwarded as a single token.
  """
  @spec parse([String.t()], flags_spec(), keyword()) ::
          {:ok, map(), [String.t()]}
          | {:ok, map(), [String.t()], [String.t()]}
          | {:error, String.t()}
  def parse(args, flags, opts \\ []) do
    # Build lookup maps for efficient flag matching
    {short_map, long_map} = build_flag_maps(flags)
    collect_unknown = Keyword.get(opts, :collect_unknown, false)

    ctx = %Context{
      short_map: short_map,
      long_map: long_map,
      command: Keyword.get(opts, :command, ""),
      allow_unknown: Keyword.get(opts, :allow_unknown, false),
      collect_unknown: collect_unknown
    }

    # Parse into a map of only the flags that were actually provided, so we can
    # distinguish "set" from "defaulted" for required-flag checking. Defaults are
    # merged in afterwards.
    with {:ok, provided, positional, extra} <- parse_loop(args, ctx, %{}, [], []),
         :ok <- check_required(flags, provided, ctx.command) do
      merged = merge_defaults(flags, provided)
      if collect_unknown, do: {:ok, merged, positional, extra}, else: {:ok, merged, positional}
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

  defp parse_loop([], _ctx, opts, positional, extra) do
    {:ok, opts, Enum.reverse(positional), Enum.reverse(extra)}
  end

  # Stop parsing flags after --
  defp parse_loop(["--" | rest], _ctx, opts, positional, extra) do
    {:ok, opts, Enum.reverse(positional) ++ rest, Enum.reverse(extra)}
  end

  # Long flag with = value: --flag=value
  defp parse_loop([<<"--", rest::binary>> = arg | args], ctx, opts, positional, extra) do
    case String.split(rest, "=", parts: 2) do
      [flag_name, value] ->
        long_flag = "--" <> flag_name

        case Map.get(ctx.long_map, long_flag) do
          {name, spec} ->
            case apply_value(opts, name, spec, value) do
              {:ok, new_opts} ->
                parse_loop(args, ctx, new_opts, positional, extra)

              {:error, _} = err ->
                err
            end

          nil ->
            # `--flag=value` is self-contained — never consume a following token as its value.
            unknown_self_contained(arg, args, ctx, opts, positional, extra)
        end

      [_flag_name] ->
        # No =, regular long flag
        parse_long_flag(arg, args, ctx, opts, positional, extra)
    end
  end

  # Short flag
  defp parse_loop([<<"-", _::binary>> = arg | args], ctx, opts, positional, extra) do
    parse_short_flag(arg, args, ctx, opts, positional, extra)
  end

  # Positional argument
  defp parse_loop([arg | args], ctx, opts, positional, extra) do
    parse_loop(args, ctx, opts, [arg | positional], extra)
  end

  defp parse_long_flag(flag, args, ctx, opts, positional, extra) do
    case Map.get(ctx.long_map, flag) do
      {name, spec} ->
        handle_flag(name, spec, args, ctx, opts, positional, extra)

      nil ->
        unknown_valued(flag, args, ctx, opts, positional, extra)
    end
  end

  defp parse_short_flag(flag, args, ctx, opts, positional, extra) do
    with nil <- Map.get(ctx.short_map, flag),
         nil <- Map.get(ctx.long_map, flag) do
      handle_unknown_short_flag(flag, args, ctx, opts, positional, extra)
    else
      {name, spec} -> handle_flag(name, spec, args, ctx, opts, positional, extra)
    end
  end

  defp handle_unknown_short_flag(flag, args, ctx, opts, positional, extra) do
    case expand_combined_flags(flag, ctx) do
      {:ok, expanded} ->
        parse_loop(expanded ++ args, ctx, opts, positional, extra)

      :error ->
        unknown_valued(flag, args, ctx, opts, positional, extra)
    end
  end

  # An unrecognized self-contained token (`--flag=value`). In collect mode it is forwarded
  # verbatim to `extra`; in allow mode it becomes a positional; otherwise it's an error.
  defp unknown_self_contained(arg, args, ctx, opts, positional, extra) do
    cond do
      ctx.collect_unknown -> parse_loop(args, ctx, opts, positional, [arg | extra])
      ctx.allow_unknown -> parse_loop(args, ctx, opts, [arg | positional], extra)
      true -> {:error, format_unknown_error(ctx.command, arg)}
    end
  end

  # An unrecognized bare flag (`--flag` or `-x`). In collect mode it is forwarded to `extra`
  # along with a following non-flag token taken as its value (the `--flag value` passthrough
  # form); in allow mode it becomes a positional; otherwise it's an error.
  defp unknown_valued(flag, args, ctx, opts, positional, extra) do
    cond do
      ctx.collect_unknown ->
        {extra, args} = consume_passthrough_value(flag, args, extra)
        parse_loop(args, ctx, opts, positional, extra)

      ctx.allow_unknown ->
        parse_loop(args, ctx, opts, [flag | positional], extra)

      true ->
        {:error, format_unknown_error(ctx.command, flag)}
    end
  end

  # Forward `flag`, plus the next token as its value when that token isn't itself a flag.
  # `extra` is built reversed, so prepend value-then-flag to keep `[flag, value]` order.
  defp consume_passthrough_value(flag, [<<"-", _::binary>> | _] = args, extra),
    do: {[flag | extra], args}

  defp consume_passthrough_value(flag, [value | rest], extra),
    do: {[value, flag | extra], rest}

  defp consume_passthrough_value(flag, [] = args, extra),
    do: {[flag | extra], args}

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

  defp handle_flag(name, spec, args, ctx, opts, positional, extra) do
    case spec[:type] do
      :boolean ->
        new_opts = Map.put(opts, name, true)
        parse_loop(args, ctx, new_opts, positional, extra)

      type when type in [:string, :integer, :float, :accumulator] ->
        case args do
          [value | rest] ->
            case apply_value(opts, name, spec, value) do
              {:ok, new_opts} ->
                parse_loop(rest, ctx, new_opts, positional, extra)

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
         {:ok, transformed} <- apply_transform(spec, typed),
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

  # A transform may return a bare value (legacy), `{:ok, value}`, or `{:error, message}`.
  # The error channel lets a single-field validation (e.g. a numeric range) fail with the
  # same shape as a type/enum error, so it flows through the caller's `with`.
  defp apply_transform(spec, value) do
    case spec[:transform] do
      nil ->
        {:ok, value}

      fun when is_function(fun, 1) ->
        case fun.(value) do
          {:ok, transformed} ->
            {:ok, transformed}

          {:error, message} when is_binary(message) ->
            {:error, ensure_newline(message)}

          {:error, other} ->
            raise ArgumentError,
                  ":transform error message must be a String.t(), got: {:error, #{inspect(other)}}"

          bare ->
            {:ok, bare}
        end
    end
  end

  defp ensure_newline(message) do
    if String.ends_with?(message, "\n"), do: message, else: message <> "\n"
  end

  defp format_unknown_error("", flag), do: "unknown option: #{flag}\n"
  defp format_unknown_error(cmd, flag), do: "#{cmd}: unknown option: #{flag}\n"
end
