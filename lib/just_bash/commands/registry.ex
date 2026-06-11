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
    "trap" => Commands.Trap,
    "eval" => Commands.Eval,
    "command" => Commands.CommandBuiltin,
    "uname" => Commands.Uname,
    "sha256sum" => Commands.Sha256sum,
    "shasum" => Commands.Shasum,
    "chmod" => Commands.Chmod,
    "chown" => Commands.Chown,
    "wget" => Commands.Wget,
    "mktemp" => Commands.Mktemp,
    "whoami" => Commands.Whoami,
    "id" => Commands.Id,
    "realpath" => Commands.Realpath,
    "nproc" => Commands.Nproc,
    "arch" => Commands.Arch,
    "yes" => Commands.Yes,
    "type" => Commands.Type,
    "xxd" => Commands.Xxd,
    "od" => Commands.Od
  }

  @optional_commands %{
    "git" => {Commands.Git, Exgit}
  }

  # Shell builtins — commands that are part of the shell itself, not external programs.
  # In real bash, these have no file on disk (or the file is a separate binary).
  # `which` should report these as builtins, not fake paths.
  @builtins MapSet.new([
              "echo",
              "printf",
              "read",
              "cd",
              "pwd",
              "export",
              "unset",
              "test",
              "[",
              "true",
              ":",
              "false",
              "set",
              "source",
              ".",
              "local",
              "declare",
              "typeset",
              "break",
              "continue",
              "shift",
              "return",
              "trap",
              "eval",
              "command",
              "getopts",
              "exit",
              "type"
            ])

  @doc """
  Get the module that implements the given command.
  """
  @spec get(String.t()) :: module() | nil
  def get(name) do
    case Map.get(@commands, name) do
      nil -> resolve_optional(name)
      mod -> mod
    end
  end

  @doc """
  Check if a command exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(name), do: Map.has_key?(@commands, name) or resolve_optional(name) != nil

  @doc """
  Check if a command is a shell builtin.
  """
  @spec builtin?(String.t()) :: boolean()
  def builtin?(name), do: MapSet.member?(@builtins, name)

  @doc """
  List all available command names.
  """
  @spec list() :: [String.t()]
  def list do
    optional =
      for {name, {_mod, dep}} <- @optional_commands, Code.ensure_loaded?(dep), do: name

    Map.keys(@commands) ++ optional
  end

  defp resolve_optional(name) do
    case Map.get(@optional_commands, name) do
      {mod, dep} -> if Code.ensure_loaded?(dep), do: mod
      nil -> nil
    end
  end
end
