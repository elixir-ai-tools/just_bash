defmodule JustBash.Commands.Id do
  @moduledoc """
  The `id` command - print real and effective user and group IDs.

  Returns simulated user/group info. Configurable via environment variables:
  - `JUST_BASH_UID` — user ID (default: "1000")
  - `JUST_BASH_GID` — group ID (default: "1000")
  """

  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command

  @impl true
  def names, do: ["id"]

  @impl true
  def execute(bash, args, _stdin) do
    user = get_username(bash)
    uid = Map.get(bash.env, "JUST_BASH_UID", "1000")
    gid = Map.get(bash.env, "JUST_BASH_GID", "1000")

    output =
      case args do
        ["-u"] -> "#{uid}\n"
        ["-g"] -> "#{gid}\n"
        ["-un"] -> "#{user}\n"
        ["-u", "-n"] -> "#{user}\n"
        ["-n", "-u"] -> "#{user}\n"
        ["-gn"] -> "#{user}\n"
        ["-g", "-n"] -> "#{user}\n"
        ["-n", "-g"] -> "#{user}\n"
        _ -> "uid=#{uid}(#{user}) gid=#{gid}(#{user}) groups=#{gid}(#{user})\n"
      end

    {Command.ok(output), bash}
  end

  defp get_username(bash) do
    Map.get(bash.env, "USER") ||
      Map.get(bash.env, "LOGNAME") ||
      bash.env |> Map.get("HOME", "/home/user") |> Path.basename()
  end
end
