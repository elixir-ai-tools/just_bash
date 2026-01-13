defmodule JustBash.Commands.Trap do
  @moduledoc """
  The `trap` builtin command - trap signals and execute commands.

  Usage: trap [command] [signal ...]
         trap -l    (list signals)
         trap -p    (print traps)

  In JustBash, only EXIT trap is fully supported since signals
  don't exist in the sandboxed environment.
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["trap"]

  @signals %{
    "EXIT" => 0,
    "0" => 0,
    "ERR" => "ERR",
    "DEBUG" => "DEBUG",
    "RETURN" => "RETURN"
  }

  @impl true
  def execute(bash, args, _stdin) do
    case args do
      [] ->
        # Print all traps
        print_traps(bash)

      ["-l"] ->
        # List signal names
        signals = "EXIT HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM"
        {Command.ok(signals <> "\n"), bash}

      ["-p"] ->
        # Print traps
        print_traps(bash)

      ["-p" | signals] ->
        # Print specific traps
        print_specific_traps(bash, signals)

      [cmd | signals] when signals != [] ->
        # Set trap
        set_traps(bash, cmd, signals)

      [_cmd] ->
        {Command.error("trap: usage: trap [-lp] [[arg] signal_spec ...]\n", 2), bash}
    end
  end

  defp print_traps(bash) do
    traps = Map.get(bash, :traps, %{})

    output =
      traps
      |> Enum.map(fn {signal, cmd} ->
        "trap -- '#{escape_single_quotes(cmd)}' #{signal}"
      end)
      |> Enum.join("\n")

    output = if output == "", do: "", else: output <> "\n"
    {Command.ok(output), bash}
  end

  defp print_specific_traps(bash, signals) do
    traps = Map.get(bash, :traps, %{})

    output =
      signals
      |> Enum.map(&normalize_signal/1)
      |> Enum.filter(&Map.has_key?(traps, &1))
      |> Enum.map(fn signal ->
        cmd = Map.get(traps, signal)
        "trap -- '#{escape_single_quotes(cmd)}' #{signal}"
      end)
      |> Enum.join("\n")

    output = if output == "", do: "", else: output <> "\n"
    {Command.ok(output), bash}
  end

  defp set_traps(bash, cmd, signals) do
    traps = Map.get(bash, :traps, %{})

    new_traps =
      Enum.reduce(signals, traps, fn signal, acc ->
        normalized = normalize_signal(signal)

        if cmd == "" or cmd == "-" do
          # Clear trap
          Map.delete(acc, normalized)
        else
          Map.put(acc, normalized, cmd)
        end
      end)

    {Command.ok(""), Map.put(bash, :traps, new_traps)}
  end

  defp normalize_signal(signal) do
    # Remove SIG prefix if present
    signal = String.replace_prefix(signal, "SIG", "")

    case Map.get(@signals, signal) do
      nil -> signal
      0 -> "EXIT"
      other -> other
    end
  end

  defp escape_single_quotes(str) do
    String.replace(str, "'", "'\\''")
  end
end
