defmodule JustBash.Commands.Registry do
  @moduledoc """
  Registry of all available bash commands.

  Maps command names to their implementing modules.
  """

  alias JustBash.Commands

  @commands %{
    "echo" => Commands.Echo,
    "true" => Commands.True,
    ":" => Commands.True,
    "false" => Commands.False,
    "pwd" => Commands.Pwd,
    "cd" => Commands.Cd,
    "cat" => Commands.Cat,
    "ls" => Commands.Ls,
    "mkdir" => Commands.Mkdir,
    "rm" => Commands.Rm,
    "touch" => Commands.Touch,
    "export" => Commands.Export,
    "unset" => Commands.Unset,
    "test" => Commands.Test,
    "[" => Commands.Test,
    "cp" => Commands.Cp,
    "mv" => Commands.Mv,
    "head" => Commands.Head,
    "tail" => Commands.Tail,
    "wc" => Commands.Wc,
    "grep" => Commands.Grep,
    "printf" => Commands.Printf,
    "basename" => Commands.Basename,
    "dirname" => Commands.Dirname,
    "read" => Commands.Read,
    "seq" => Commands.Seq,
    "sort" => Commands.Sort,
    "uniq" => Commands.Uniq,
    "tr" => Commands.Tr,
    "date" => Commands.Date,
    "sleep" => Commands.Sleep,
    "exit" => Commands.Exit
  }

  @doc """
  Get the module that implements the given command.
  """
  @spec get(String.t()) :: module() | nil
  def get(name), do: Map.get(@commands, name)

  @doc """
  Check if a command exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(name), do: Map.has_key?(@commands, name)

  @doc """
  List all available command names.
  """
  @spec list() :: [String.t()]
  def list, do: Map.keys(@commands)
end
