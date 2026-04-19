if Code.ensure_loaded?(Exgit) do
  defmodule JustBash.Commands.Git do
    @moduledoc """
    The `git` command — git operations backed by Exgit.

    Currently supports `git clone`, which lazily mounts a `GitFS` backend at the
    target path instead of materializing files.

    Git must be explicitly enabled via `JustBash.new(git: %{enabled: true})`.
    Credentials are read from `bash.git.credentials`, set by the host application
    and never exposed inside the sandbox.
    """
    @behaviour JustBash.Commands.Command

    alias Exgit.Object.Commit
    alias Exgit.ObjectStore
    alias JustBash.Commands.Command
    alias JustBash.Fs
    alias JustBash.Fs.GitFS

    @impl true
    def names, do: ["git"]

    @impl true
    def execute(bash, args, _stdin) do
      if bash.git.enabled do
        dispatch(bash, args)
      else
        {Command.error("git: command not available (git access is disabled)\n", 127), bash}
      end
    end

    defp dispatch(bash, ["clone" | rest]), do: do_clone(bash, rest)

    defp dispatch(bash, [subcmd | _]),
      do: {Command.error("git: '#{subcmd}' is not a git command\n"), bash}

    defp dispatch(bash, []), do: {Command.error("usage: git <command> [<args>]\n"), bash}

    defp do_clone(bash, args) do
      {opts, positional} = parse_clone_args(args)

      case positional do
        [url | rest] ->
          target = clone_target(url, List.first(rest))
          resolved = Fs.resolve_path(bash.cwd, target)
          writable = not Keyword.get(opts, :bare, false)

          clone_opts =
            case bash.git.credentials do
              nil -> []
              auth -> [auth: auth]
            end

          case Exgit.clone(url, clone_opts) do
            {:ok, repo} ->
              git_state = build_git_state(repo, writable)
              mount_clone(bash, resolved, git_state, target)

            {:error, reason} ->
              {Command.error("fatal: #{format_error(reason)}\n", 128), bash}
          end

        [] ->
          {Command.error("fatal: You must specify a repository to clone.\n", 128), bash}
      end
    end

    defp parse_clone_args(args) do
      Enum.reduce(args, {[], []}, fn
        "--bare", {opts, pos} -> {[{:bare, true} | opts], pos}
        "--" <> _flag, {opts, pos} -> {opts, pos}
        arg, {opts, pos} -> {opts, pos ++ [arg]}
      end)
    end

    defp clone_target(url, nil) do
      url
      |> String.trim_trailing("/")
      |> String.trim_trailing(".git")
      |> String.split("/")
      |> List.last()
    end

    defp clone_target(_url, explicit), do: explicit

    defp build_git_state(repo, writable) do
      tree = resolve_tree(repo)
      %GitFS{repo: repo, ref: "HEAD", tree: tree, writable: writable}
    end

    defp resolve_tree(repo) do
      case Exgit.RefStore.resolve(repo.ref_store, "HEAD") do
        {:ok, commit_sha} ->
          case ObjectStore.get(repo.object_store, commit_sha) do
            {:ok, %Commit{} = c} -> Commit.tree(c)
            _ -> nil
          end

        _ ->
          nil
      end
    end

    defp mount_clone(bash, resolved, git_state, display_name) do
      case Fs.mount(bash.fs, resolved, GitFS, git_state) do
        {:ok, new_fs} ->
          msg = "Cloning into '#{display_name}'...\n"
          {Command.result(msg, "", 0), %{bash | fs: new_fs}}

        {:error, :eexist} ->
          {Command.error(
             "fatal: destination path '#{display_name}' already exists.\n",
             128
           ), bash}

        {:error, reason} ->
          {Command.error("fatal: #{reason}\n", 128), bash}
      end
    end

    defp format_error(:not_found), do: "repository not found"
    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: inspect(reason)
  end
end
