defmodule JustBash.Commands.Uname do
  @moduledoc """
  The `uname` builtin - print system information.

  Returns simulated system information based on environment variables:
  - `JUST_BASH_OS` — kernel name (default: "Linux")
  - `JUST_BASH_ARCH` — machine architecture (default: "x86_64")
  - `JUST_BASH_HOSTNAME` — node name (default: "localhost")
  - `JUST_BASH_KERNEL_RELEASE` — kernel release (default: "5.15.0")

  Flags: -s (kernel name), -m (machine), -n (node name), -r (release), -a (all).
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["uname"]

  @impl true
  def execute(bash, args, _stdin) do
    flags = parse_flags(args)
    info = system_info(bash.env)

    output =
      cond do
        :all in flags ->
          "#{info.sysname} #{info.nodename} #{info.release} #1 SMP #{info.machine}\n"

        flags == [] ->
          "#{info.sysname}\n"

        true ->
          Enum.map_join(flags, " ", fn
            :sysname -> info.sysname
            :machine -> info.machine
            :nodename -> info.nodename
            :release -> info.release
          end) <> "\n"
      end

    {Command.ok(output), bash}
  end

  defp system_info(env) do
    %{
      sysname: Map.get(env, "JUST_BASH_OS", "Linux"),
      machine: Map.get(env, "JUST_BASH_ARCH", "x86_64"),
      nodename: Map.get(env, "JUST_BASH_HOSTNAME", "localhost"),
      release: Map.get(env, "JUST_BASH_KERNEL_RELEASE", "5.15.0")
    }
  end

  defp parse_flags(args) do
    Enum.flat_map(args, fn
      "-a" -> [:all]
      "-s" -> [:sysname]
      "-m" -> [:machine]
      "-n" -> [:nodename]
      "-r" -> [:release]
      "-" <> combo -> parse_combo(combo)
      _ -> []
    end)
  end

  defp parse_combo(chars) do
    chars
    |> String.graphemes()
    |> Enum.flat_map(fn
      "a" -> [:all]
      "s" -> [:sysname]
      "m" -> [:machine]
      "n" -> [:nodename]
      "r" -> [:release]
      _ -> []
    end)
  end
end
