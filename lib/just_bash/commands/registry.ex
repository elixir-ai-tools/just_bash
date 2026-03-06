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
    "exit" => Commands.Exit,
    "cut" => Commands.Cut,
    "tee" => Commands.Tee,
    "env" => Commands.Env,
    "printenv" => Commands.Printenv,
    "which" => Commands.Which,
    "ln" => Commands.Ln,
    "tac" => Commands.Tac,
    "rev" => Commands.Rev,
    "nl" => Commands.Nl,
    "base64" => Commands.Base64,
    "readlink" => Commands.Readlink,
    "hostname" => Commands.Hostname,
    "fold" => Commands.Fold,
    "stat" => Commands.Stat,
    "du" => Commands.Du,
    "paste" => Commands.Paste,
    "comm" => Commands.Comm,
    "expand" => Commands.Expand,
    "md5sum" => Commands.Md5sum,
    "diff" => Commands.Diff,
    "tree" => Commands.Tree,
    "file" => Commands.File,
    "find" => Commands.Find,
    "xargs" => Commands.Xargs,
    "sed" => Commands.Sed,
    "awk" => Commands.Awk,
    "curl" => Commands.Curl,
    "jq" => Commands.Jq,
    "set" => Commands.Set,
    "source" => Commands.Source,
    "." => Commands.Source,
    "markdown" => Commands.Markdown,
    "md" => Commands.Markdown,
    "local" => Commands.Local,
    "declare" => Commands.Local,
    "typeset" => Commands.Local,
    "break" => Commands.Break,
    "continue" => Commands.Continue,
    "shift" => Commands.Shift,
    "return" => Commands.Return,
    "getopts" => Commands.Getopts,
    "trap" => Commands.Trap
  }

  @doc """
  Get the module that implements the given command.
  """
  @spec get(JustBash.t(), String.t()) :: module() | nil
  def get(bash, cmd) do
    get_custom(bash, cmd) || Map.get(@commands, cmd)
  end

  @doc """
  Check if a command exists.
  """
  @spec exists?(JustBash.t(), String.t()) :: boolean()
  def exists?(bash, name) do
    Map.has_key?(@commands, name) || exists_custom?(bash, name)
  end

  @doc """
  List all available command names.
  """
  @spec list(JustBash.t()) :: [String.t()]
  def list(bash) do
    Enum.uniq(Map.keys(@commands) ++ list_custom(bash))
  end

  defp get_custom(%JustBash{custom_builtin_registry: nil}, _cmd), do: nil

  defp get_custom(%JustBash{custom_builtin_registry: module}, cmd) when is_atom(module) do
    module.get(cmd)
  end

  defp get_custom(%JustBash{custom_builtin_registry: {module, ctx}}, cmd) do
    module.get(cmd, ctx)
  end

  defp exists_custom?(%JustBash{custom_builtin_registry: nil}, _cmd), do: false

  defp exists_custom?(%JustBash{custom_builtin_registry: module}, cmd) when is_atom(module) do
    module.exists?(cmd)
  end

  defp exists_custom?(%JustBash{custom_builtin_registry: {module, ctx}}, cmd) do
    module.exists?(cmd, ctx)
  end

  defp list_custom(%JustBash{custom_builtin_registry: nil}), do: []

  defp list_custom(%JustBash{custom_builtin_registry: module}) when is_atom(module) do
    module.list()
  end

  defp list_custom(%JustBash{custom_builtin_registry: {module, ctx}}) do
    module.list(ctx)
  end
end
