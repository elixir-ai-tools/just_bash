defmodule JustBash.Commands.Getopts do
  @moduledoc """
  The `getopts` builtin command - parse positional parameters as options.

  Usage: getopts optstring name [args...]

  Parses command-line options. Each call processes the next option.
  Returns 0 if an option is found, 1 when options are exhausted.

  The optstring contains the option letters. A colon after a letter
  means that option requires an argument.

  Sets:
  - name: the option letter found (or ? for unknown/missing arg)
  - OPTARG: the option's argument (if any)
  - OPTIND: index of next argument to process
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["getopts"]

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [optstring, name | rest] ->
        # Get arguments to parse (either from rest or positional params)
        parse_args = if rest == [], do: get_positional_args(bash), else: rest
        process_option(bash, optstring, name, parse_args)

      _ ->
        {Command.error("getopts: usage: getopts optstring name [arg ...]\n", 2), bash}
    end
  end

  defp get_positional_args(bash) do
    count = Map.get(bash.env, "#", "0") |> String.to_integer()

    1..count
    |> Enum.map(fn i -> Map.get(bash.env, to_string(i), "") end)
  end

  defp process_option(bash, optstring, name, args) do
    # Get current OPTIND (1-based index into args)
    optind = Map.get(bash.env, "OPTIND", "1") |> String.to_integer()
    index = optind - 1

    if index >= length(args) do
      # No more arguments
      env = Map.put(bash.env, name, "?")
      {%{stdout: "", stderr: "", exit_code: 1}, %{bash | env: env}}
    else
      arg = Enum.at(args, index)
      parse_argument(bash, optstring, name, arg, args, optind)
    end
  end

  defp parse_argument(bash, optstring, name, arg, args, optind) do
    cond do
      # Not an option (doesn't start with -)
      not String.starts_with?(arg, "-") ->
        env = Map.put(bash.env, name, "?")
        {%{stdout: "", stderr: "", exit_code: 1}, %{bash | env: env}}

      # End of options marker
      arg == "--" ->
        env =
          bash.env
          |> Map.put(name, "?")
          |> Map.put("OPTIND", to_string(optind + 1))

        {%{stdout: "", stderr: "", exit_code: 1}, %{bash | env: env}}

      # Option
      true ->
        parse_option_char(bash, optstring, name, arg, args, optind)
    end
  end

  defp parse_option_char(bash, optstring, name, arg, args, optind) do
    # Get the option character (skip the leading -)
    opt_char = String.at(arg, 1)

    if opt_char == nil do
      # Just "-" by itself
      env = Map.put(bash.env, name, "?")
      {%{stdout: "", stderr: "", exit_code: 1}, %{bash | env: env}}
    else
      handle_option(bash, optstring, name, opt_char, arg, args, optind)
    end
  end

  defp handle_option(bash, optstring, name, opt_char, arg, args, optind) do
    # Check if option is in optstring
    opt_index = find_option(optstring, opt_char)

    cond do
      opt_index == nil ->
        # Unknown option
        env =
          bash.env
          |> Map.put(name, "?")
          |> Map.put("OPTARG", opt_char)
          |> Map.put("OPTIND", to_string(optind + 1))

        stderr =
          if String.starts_with?(optstring, ":") do
            ""
          else
            "getopts: illegal option -- #{opt_char}\n"
          end

        {%{stdout: "", stderr: stderr, exit_code: 0}, %{bash | env: env}}

      needs_argument?(optstring, opt_index) ->
        # Option requires argument
        handle_option_with_arg(bash, name, opt_char, arg, args, optind, optstring)

      true ->
        # Option without argument
        remaining = String.slice(arg, 2..-1//1)

        env =
          if remaining == "" do
            # Move to next arg
            bash.env
            |> Map.put(name, opt_char)
            |> Map.delete("OPTARG")
            |> Map.put("OPTIND", to_string(optind + 1))
          else
            # More options in this arg, stay on same arg but track position
            # For simplicity, we'll just advance to next arg
            bash.env
            |> Map.put(name, opt_char)
            |> Map.delete("OPTARG")
            |> Map.put("OPTIND", to_string(optind + 1))
          end

        {Command.ok(""), %{bash | env: env}}
    end
  end

  defp handle_option_with_arg(bash, name, opt_char, arg, args, optind, optstring) do
    remaining = String.slice(arg, 2..-1//1)

    cond do
      remaining != "" ->
        # Argument is attached: -fvalue
        env =
          bash.env
          |> Map.put(name, opt_char)
          |> Map.put("OPTARG", remaining)
          |> Map.put("OPTIND", to_string(optind + 1))

        {Command.ok(""), %{bash | env: env}}

      optind < length(args) ->
        # Argument is next positional param
        opt_arg = Enum.at(args, optind)

        env =
          bash.env
          |> Map.put(name, opt_char)
          |> Map.put("OPTARG", opt_arg)
          |> Map.put("OPTIND", to_string(optind + 2))

        {Command.ok(""), %{bash | env: env}}

      true ->
        # Missing required argument
        env =
          bash.env
          |> Map.put(name, if(String.starts_with?(optstring, ":"), do: ":", else: "?"))
          |> Map.put("OPTARG", opt_char)
          |> Map.put("OPTIND", to_string(optind + 1))

        stderr =
          if String.starts_with?(optstring, ":") do
            ""
          else
            "getopts: option requires an argument -- #{opt_char}\n"
          end

        {%{stdout: "", stderr: stderr, exit_code: 0}, %{bash | env: env}}
    end
  end

  defp find_option(optstring, char) do
    # Skip leading : if present
    opts =
      if String.starts_with?(optstring, ":"),
        do: String.slice(optstring, 1..-1//1),
        else: optstring

    case :binary.match(opts, char) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp needs_argument?(optstring, opt_index) do
    # Check if there's a : after the option
    opts =
      if String.starts_with?(optstring, ":"),
        do: String.slice(optstring, 1..-1//1),
        else: optstring

    String.at(opts, opt_index + 1) == ":"
  end
end
