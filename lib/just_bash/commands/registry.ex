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
    "sqlite3" => Commands.Sqlite3,
    "liquid" => Commands.Liquid,
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
